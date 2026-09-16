import Foundation
import CryptoKit
import Security

// MARK: - Account Backup Manager
//
// Backs up Telegram account auth data — `accounts-metadata` plus the compact
// network/session state from every `account-*` directory — into a single
// AES-256-GCM encrypted archive stored inside the app data directory.
// Message databases, media, caches and other re-downloadable data are excluded
// so the Keychain copy stays small and responsive like Swiftgram's backup.
// The archive's encryption key lives in the device Keychain and never leaves it.
//
// Restore is two-phase so it can never corrupt a live postbox:
//   1. prepareRestore()  — decrypts the archive into a staging directory and
//      raises the pending-restore flag (runs while the user is in the app).
//   2. applyPendingRestoreIfNeeded(rootPath:) — runs at the very start of the
//      next cold launch, BEFORE any postbox is opened, snapshots the current
//      account data for safety, then swaps the staged data into place.
public final class AccountBackupManager {
    public static let shared = AccountBackupManager()
    private init() {}

    // MARK: - Constants

    private let keychainService   = "aorusgram_account_backup"
    private let keychainKeyName   = "aes256_key_v1"
    private let rootPathKey       = "aorusgram_root_path"
    private let pendingRestoreKey = "aorusgram_pending_restore_v1"
    private let metaDateKey       = "aorusgram_backup_date_v1"
    private let metaCountKey      = "aorusgram_backup_accounts_v1"
    private let metaSizeKey       = "aorusgram_backup_size_v1"
    // Persisted at backup time so the login-by-backup picker can list the
    // backed-up accounts without decrypting the archive (and even after the
    // on-disk account folders are gone, e.g. after a sign-out).
    private let metaIdsKey        = "aorusgram_backup_account_ids_v1"

    // Durable Keychain storage. iOS Keychain items (unlike files and UserDefaults)
    // survive an app uninstall/reinstall for the same bundle id, so the whole
    // encrypted backup — the AES key, the archive bytes (chunked), and the
    // account metadata — lives here. This is what makes the backup outlast a
    // reinstall the way the Swiftgram Keychain backup does.
    private let keychainMetaName   = "archive_meta_v1"
    private let keychainChunkPrefix = "archive_chunk_"
    private let keychainChunkSize  = 200 * 1024   // 200 KB per Keychain item — safely small.
    private let maxCompactBackupFileSize: UInt64 = 2 * 1024 * 1024
    private let maxEncryptedEntrySize: UInt64 = 4 * 1024 * 1024
    private let maxEncryptedArchiveSize: UInt64 = 256 * 1024 * 1024
    private let maxArchiveEntryCount = 50_000
    private let maxEncryptedPathSize: UInt32 = 64 * 1024

    // Per-account display data, captured at backup time, so the Sessions list and
    // the login-by-backup picker can show a real username / Telegram ID / avatar
    // even after a reinstall (the values live in the durable Keychain metadata).
    public struct AccountRecordMeta: Codable, Equatable {
        public var id: String            // account-record id (matches the on-disk dir)
        public var userId: Int64         // Telegram user id (shown as "ID: …")
        public var username: String?     // @handle, if any
        public var name: String          // display title
        public var avatarBase64: String? // small PNG, if a cached photo existed
        public init(id: String, userId: Int64, username: String?, name: String, avatarBase64: String?) {
            self.id = id
            self.userId = userId
            self.username = username
            self.name = name
            self.avatarBase64 = avatarBase64
        }
    }

    // Input to performBackup — the live display data gathered from the account contexts.
    public struct AccountDisplayInfo {
        public let id: String
        public let userId: Int64
        public let username: String?
        public let name: String
        public let avatarPNG: Data?
        public init(id: String, userId: Int64, username: String?, name: String, avatarPNG: Data?) {
            self.id = id
            self.userId = userId
            self.username = username
            self.name = name
            self.avatarPNG = avatarPNG
        }
    }

    private struct KeychainBackupMeta: Codable {
        var chunkCount: Int
        var sizeBytes: Int64
        var date: Double         // timeIntervalSince1970
        var accountCount: Int
        var accountIds: [String]
        var accounts: [AccountRecordMeta]?
        /// Which set of chunk items this metadata describes.
        ///
        /// Chunks used to be written under one fixed set of names, which meant a new backup
        /// had to delete the old chunks before it could write its own: an error or a kill in
        /// the middle left the durable copy half-erased and unusable. A new backup now writes
        /// a new generation alongside the old one, and this field — written last, in a single
        /// Keychain item — is the commit. Absent in metadata written before generations
        /// existed, which is generation 0 and the unsuffixed chunk names.
        var generation: Int?
    }

    private static let archiveName  = "aorus-account-backup.enc"
    private static let stagingName  = ".aorus-restore-staging"
    private static let snapshotPrefix = ".aorus-prerestore-"
    private static let pendingFlagKey = "aorusgram_pending_restore_v1"
    private static let pendingMergeFlagKey = "aorusgram_pending_restore_merge_v1"
    private static let pendingSelectedAccountKey = "aorusgram_pending_restore_account_id_v1"

    // The archive format itself — framing, per-entry associated data and the sealed manifest —
    // lives in AorusBackupArchive so it can be compiled and exercised on its own.
    private let maxSealedManifestSize: UInt64 = 32 * 1024 * 1024

    private var archiveLimits: AorusBackupArchive.Limits {
        return AorusBackupArchive.Limits(
            maxEntryCount: maxArchiveEntryCount,
            maxSealedPathSize: maxEncryptedPathSize,
            maxSealedEntrySize: maxEncryptedEntrySize,
            maxSealedArchiveSize: maxEncryptedArchiveSize,
            maxSealedManifestSize: maxSealedManifestSize
        )
    }

    // The AorusGram core module and AorusGramUI both compile this file and it has to stay
    // byte-identical between them (release_security_check enforces that), so it can reach
    // neither module's translation table — AorusGramUI sits above AorusGram, and importing
    // it here would be a cycle. These sixteen backup failures are the only strings the
    // manager shows, so they are resolved from a table right here.
    //
    // The order matches aorusL(): Telegram's language first, the device only when Telegram
    // has none yet, which happens on a fresh install with no account.
    private func localized(_ ru: String, _ en: String) -> String {
        let code = (UserDefaults.standard.string(forKey: "aorusgram_lang_code")
            ?? UserDefaults.standard.string(forKey: "aorusgram_lang")
            ?? Locale.preferredLanguages.first
            ?? "en").lowercased()
        // Full code first, then the base — see AorusLang.resolve: "zh-hans" and "zh-hant" are
        // separate packs and must not collapse into one.
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        let base = String(normalized.prefix(while: { $0 != "-" }))
        if base == "ru" {
            return ru
        }
        if let exact = AccountBackupL10n.tables[normalized]?[en] {
            return exact
        }
        return AccountBackupL10n.tables[base]?[en] ?? en
    }

    // MARK: - Root path

    // Mirrored to UserDefaults so the AorusGramUI copy of this manager reads the
    // same value. Set once by AorusGramBootstrap.setup(accountPath:).
    public var rootPath: String {
        get { UserDefaults.standard.string(forKey: rootPathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: rootPathKey) }
    }

    private var archiveURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(Self.archiveName)
    }
    private var stagingURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(Self.stagingName)
    }

    // MARK: - Public model

    public struct BackupInfo {
        public let date: Date
        public let accountCount: Int
        public let sizeBytes: Int64
    }

    public enum BackupOutcome {
        case success(BackupInfo)
        case failure(String)
    }

    // MARK: - Status

    public func hasBackup() -> Bool {
        // The AES key is mandatory; the archive may live on disk (fast path) or,
        // after a reinstall wiped the sandbox, only in the Keychain.
        guard loadKey() != nil else { return false }
        if FileManager.default.fileExists(atPath: archiveURL.path) { return true }
        return keychainMeta() != nil
    }

    // Account record IDs captured in the last backup — the source of truth for the
    // login-by-backup picker. Reads the durable Keychain metadata first (survives a
    // reinstall), then the UserDefaults mirror, then whatever is on disk.
    public func backupAccountIds() -> [String] {
        if let meta = keychainMeta(), !meta.accountIds.isEmpty {
            return meta.accountIds
        }
        if let ids = UserDefaults.standard.stringArray(forKey: metaIdsKey), !ids.isEmpty {
            return ids
        }
        return localAccountIds()
    }

    public func isRestorePending() -> Bool {
        return UserDefaults.standard.bool(forKey: pendingRestoreKey)
    }

    public func backupInfo() -> BackupInfo? {
        guard loadKey() != nil else { return nil }
        // Durable Keychain metadata wins — it is present even right after a reinstall,
        // when the UserDefaults mirror has been wiped.
        if let meta = keychainMeta() {
            return BackupInfo(
                date: Date(timeIntervalSince1970: meta.date),
                accountCount: meta.accountCount,
                sizeBytes: meta.sizeBytes
            )
        }
        let ud = UserDefaults.standard
        guard FileManager.default.fileExists(atPath: archiveURL.path),
              let date = ud.object(forKey: metaDateKey) as? Date else { return nil }
        return BackupInfo(
            date: date,
            accountCount: ud.integer(forKey: metaCountKey),
            sizeBytes: Int64(ud.integer(forKey: metaSizeKey))
        )
    }

    // Per-account display metadata captured in the last backup (for the Sessions
    // list). Empty if the backup predates display capture.
    public func backupAccounts() -> [AccountRecordMeta] {
        return keychainMeta()?.accounts ?? []
    }

    // Account record IDs present on disk (the `account-<id>` directory suffix).
    public func localAccountIds() -> [String] {
        let fm = FileManager.default
        guard !rootPath.isEmpty,
              let entries = try? fm.contentsOfDirectory(atPath: rootPath) else { return [] }
        return entries
            .filter { $0.hasPrefix("account-") && !$0.contains(".aorus") }
            .map { String($0.dropFirst("account-".count)) }
            .sorted()
    }

    // MARK: - Backup

    public func performBackup(displayInfos: [AccountDisplayInfo] = []) -> BackupOutcome {
        guard !rootPath.isEmpty else { return .failure(localized("Путь к данным аккаунтов недоступен", "Account data path is unavailable")) }
        let fm = FileManager.default

        var files: [(abs: String, rel: String)] = []
        collectBackupFiles(into: &files)
        guard !files.isEmpty else { return .failure(localized("Нет данных аккаунтов для бэкапа", "No account data available for backup")) }
        guard files.count <= maxArchiveEntryCount else {
            return .failure(localized("Бэкап слишком большой", "Backup is too large"))
        }

        let key = loadKey() ?? SymmetricKey(size: .bits256)

        // The key is committed BEFORE the archive, and never by deleting the live one. The old
        // order wrote the archive over the previous one first and, if the key then failed to
        // save, deleted the archive it had just written — so a failed backup destroyed the
        // working backup and, because saveKey deleted before it added, could destroy the key
        // that made the Keychain copy readable as well.
        guard saveKey(key) else {
            return .failure(localized("Не удалось сохранить ключ в Keychain", "Failed to save key in Keychain"))
        }

        let tmpURL = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(Self.archiveName + ".tmp")
        var cursor = 0
        do {
            try AorusBackupArchive.write(to: tmpURL, key: key, limits: archiveLimits) {
                guard cursor < files.count else { return nil }
                let file = files[cursor]
                cursor += 1
                guard let content = fm.contents(atPath: file.abs) else {
                    throw AorusBackupArchive.Failure.encryption
                }
                return AorusBackupArchive.Entry(path: file.rel, body: content)
            }
        } catch AorusBackupArchive.Failure.tooLarge {
            try? fm.removeItem(at: tmpURL)
            return .failure(localized("Бэкап слишком большой", "Backup is too large"))
        } catch AorusBackupArchive.Failure.io {
            try? fm.removeItem(at: tmpURL)
            return .failure(localized("Не удалось создать файл бэкапа", "Failed to create backup file"))
        } catch {
            try? fm.removeItem(at: tmpURL)
            return .failure(localized("Ошибка шифрования данных", "Data encryption failed"))
        }

        // Atomic replace. The previous archive is only unlinked once the new one is in place,
        // so an interrupted commit leaves the old backup whole instead of leaving nothing.
        do {
            try commitArchive(from: tmpURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            return .failure(localized("Не удалось сохранить бэкап", "Failed to save backup"))
        }

        let attrs = try? fm.attributesOfItem(atPath: archiveURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let ids = localAccountIds()
        let info = BackupInfo(date: Date(), accountCount: ids.count, sizeBytes: size)

        // Build durable per-account display metadata (only for accounts still on disk).
        let idSet = Set(ids)
        let accountMetas: [AccountRecordMeta] = displayInfos.filter { idSet.contains($0.id) }.map {
            AccountRecordMeta(id: $0.id, userId: $0.userId, username: $0.username, name: $0.name, avatarBase64: $0.avatarPNG?.base64EncodedString())
        }

        // Mirror the encrypted archive + metadata into the Keychain so the whole
        // backup survives an app reinstall (files and UserDefaults do not).
        guard storeArchiveInKeychain(accountIds: ids, date: info.date, accountCount: info.accountCount, accounts: accountMetas) else {
            return .failure(localized("Не удалось сохранить бэкап в Keychain", "Failed to save backup to Keychain"))
        }

        let ud = UserDefaults.standard
        ud.set(info.date, forKey: metaDateKey)
        ud.set(info.accountCount, forKey: metaCountKey)
        ud.set(Int(info.sizeBytes), forKey: metaSizeKey)
        ud.set(ids, forKey: metaIdsKey)
        return .success(info)
    }

    /// Moves a freshly written archive into place without a window where neither exists.
    ///
    /// `replaceItemAt` swaps the inode and only then discards the old file; the previous code
    /// removed the destination first and moved afterwards, so a failure or a kill between the
    /// two left the user with no archive at all.
    private func commitArchive(from tmpURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: archiveURL.path) {
            _ = try fm.replaceItemAt(archiveURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: archiveURL)
        }
    }

    private func collectBackupFiles(into files: inout [(abs: String, rel: String)]) {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(atPath: rootPath) else { return }
        for name in top {
            let isMeta = (name == "accounts-metadata")
            let isAccount = name.hasPrefix("account-") && !name.contains(".aorus")
            guard isMeta || isAccount else { continue }
            let dirAbs = (rootPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirAbs, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if shouldIncludeBackupFile(abs: dirAbs, rel: name) {
                    files.append((abs: dirAbs, rel: name))
                }
                continue
            }
            enumerate(dirAbs: dirAbs, relBase: name, into: &files)
        }
    }

    private func enumerate(dirAbs: String, relBase: String,
                           into files: inout [(abs: String, rel: String)]) {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dirAbs) else { return }
        while let sub = en.nextObject() as? String {
            let abs = (dirAbs as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir) else { continue }
            let rel = relBase + "/" + sub
            if isDir.boolValue {
                if shouldSkipBackupDirectory(rel: rel) {
                    en.skipDescendants()
                }
                continue
            }
            if shouldIncludeBackupFile(abs: abs, rel: rel) {
                files.append((abs: abs, rel: rel))
            }
        }
    }

    private func shouldSkipBackupDirectory(rel: String) -> Bool {
        let comps = rel.split(separator: "/").map { String($0).lowercased() }
        guard comps.count >= 2 else { return false }
        let heavyRoots: Set<String> = [
            "postbox", "mediabox", "media", "cache", "caches", "temp", "tmp",
            "resources", "resource-cache", "stickers", "video", "audio"
        ]
        return comps.contains(where: { heavyRoots.contains($0) || $0.contains("cache") || $0.contains("temp") || $0.contains("tmp") })
    }

    private func shouldIncludeBackupFile(abs: String, rel: String) -> Bool {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: abs)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let comps = rel.split(separator: "/").map(String.init)
        guard let first = comps.first else { return false }

        if first == "accounts-metadata" {
            return size <= maxCompactBackupFileSize
        }
        guard first.hasPrefix("account-"), comps.count >= 2 else { return false }
        guard size <= maxCompactBackupFileSize else { return false }

        if shouldSkipBackupDirectory(rel: rel) {
            return false
        }

        let second = comps[1].lowercased()
        if second == "network" || second.contains("network") || second.contains("auth")
            || second.contains("session") || second.contains("state")
            || second.contains("metadata") || second.contains("config")
            || second.contains("preference") || second.contains("mtproto")
            || second.contains("datacenter") {
            return true
        }

        let lowerRel = rel.lowercased()
        if lowerRel.hasSuffix(".sqlite") || lowerRel.hasSuffix(".sqlite-wal")
            || lowerRel.hasSuffix(".sqlite-shm") || lowerRel.hasSuffix(".db")
            || lowerRel.hasSuffix(".ldb") || lowerRel.hasSuffix(".log") {
            return false
        }

        // Keep small root-level account metadata files, but never descend into broad
        // stores such as postbox/media. Telegram recreates message databases after login.
        return comps.count == 2
    }

    // MARK: - Restore phase 1: prepare

    public func prepareRestore(selectedAccountId: String? = nil, mergeIntoExisting: Bool = false) -> BackupOutcome {
        guard !rootPath.isEmpty else { return .failure(localized("Путь к данным аккаунтов недоступен", "Account data path is unavailable")) }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.pendingFlagKey)
        defaults.set(false, forKey: Self.pendingMergeFlagKey)
        defaults.removeObject(forKey: Self.pendingSelectedAccountKey)
        let selectedAccountId = selectedAccountId.flatMap { Int64($0) != nil ? $0 : nil }
        if mergeIntoExisting && selectedAccountId == nil {
            return .failure(localized("Не выбран аккаунт для добавления", "No account selected to add"))
        }
        // Rebuild the archive file from the durable Keychain copy if the sandbox
        // was wiped (e.g. after a reinstall) so the streaming decode below works.
        materializeArchiveFromKeychainIfNeeded()
        guard hasBackup(), let key = loadKey() else { return .failure(localized("Бэкап не найден", "Backup not found")) }
        let fm = FileManager.default

        guard fm.fileExists(atPath: archiveURL.path) else {
            return .failure(localized("Не удалось открыть бэкап", "Failed to open backup"))
        }

        // A pre-v2 archive is upgraded in place before anything reads it. v1 authenticated
        // each box on its own and nothing about the archive's shape, so entries could be
        // reordered, dropped or spliced in from another archive with every remaining tag
        // still verifying. The reader below accepts v2 only.
        if migrateLegacyArchive(key: key) == .failed {
            return .failure(localized("Файл бэкапа повреждён", "Backup file is corrupted"))
        }

        try? fm.removeItem(at: stagingURL)
        do {
            try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        } catch {
            return .failure(localized("Не удалось создать папку восстановления", "Failed to create restore folder"))
        }

        do {
            try AorusBackupArchive.read(url: archiveURL, key: key, limits: archiveLimits) { entry in
                guard isSafeRelativePath(entry.path) else { throw AorusBackupArchive.Failure.corrupt }
                if mergeIntoExisting, let selectedAccountId {
                    let accountRoot = "account-" + selectedAccountId
                    let belongsToSelection = entry.path == "accounts-metadata/atomic-state"
                        || entry.path == accountRoot
                        || entry.path.hasPrefix(accountRoot + "/")
                    // Entries outside the selection are still decrypted and verified — the
                    // manifest covers the whole archive, so skipping them here would leave a
                    // dropped or transplanted entry undetected. They are only not written out.
                    if !belongsToSelection { return }
                }
                let dest = stagingURL.appendingPathComponent(entry.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try entry.body.write(to: dest)
            }
        } catch {
            // Staging is scratch space precisely so this can happen: the archive is verified
            // whole, manifest included, before the pending flag is raised below, and nothing
            // that failed verification ever reaches the live account directories.
            try? fm.removeItem(at: stagingURL)
            return .failure(localized("Ошибка расшифровки бэкапа", "Backup decryption failed"))
        }

        if let selectedAccountId {
            guard Self.selectCurrentAccount(in: stagingURL, accountId: selectedAccountId) else {
                try? fm.removeItem(at: stagingURL)
                return .failure(localized("Аккаунт отсутствует в бэкапе", "The selected account is missing from the backup"))
            }
        }

        if mergeIntoExisting, let selectedAccountId {
            let accountURL = stagingURL.appendingPathComponent("account-" + selectedAccountId, isDirectory: true)
            guard fm.fileExists(atPath: accountURL.path) else {
                try? fm.removeItem(at: stagingURL)
                return .failure(localized("Данные выбранного аккаунта отсутствуют", "The selected account data is missing"))
            }
            UserDefaults.standard.set(true, forKey: Self.pendingMergeFlagKey)
            UserDefaults.standard.set(selectedAccountId, forKey: Self.pendingSelectedAccountKey)
        } else {
            UserDefaults.standard.set(false, forKey: Self.pendingMergeFlagKey)
            UserDefaults.standard.removeObject(forKey: Self.pendingSelectedAccountKey)
        }

        UserDefaults.standard.set(true, forKey: pendingRestoreKey)
        let info = backupInfo()
            ?? BackupInfo(date: Date(), accountCount: localAccountIds().count, sizeBytes: 0)
        return .success(info)
    }

    public func cancelPendingRestore() {
        UserDefaults.standard.set(false, forKey: pendingRestoreKey)
        UserDefaults.standard.set(false, forKey: Self.pendingMergeFlagKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingSelectedAccountKey)
        try? FileManager.default.removeItem(at: stagingURL)
    }

    // MARK: - Legacy archive migration

    private enum LegacyMigration: Equatable {
        case notNeeded
        case migrated
        case failed
    }

    /// Rewrites a v1 archive as v2, atomically, in one streaming pass.
    ///
    /// This is the controlled migration the format change needs: the restore path refuses v1,
    /// and a user whose only backup is v1 must not lose it. It needs no account data — only
    /// the key — and never holds more than one entry at a time, in memory, in plaintext.
    ///
    /// It cannot retroactively authenticate what v1 never authenticated: a v1 archive that was
    /// already tampered with migrates faithfully, tampering included. What it fixes is every
    /// archive from here on, and it fixes it without asking the user to make a new backup.
    private func migrateLegacyArchive(key: SymmetricKey) -> LegacyMigration {
        let fm = FileManager.default
        guard let probe = try? FileHandle(forReadingFrom: archiveURL) else { return .failed }
        let head = probe.readData(ofLength: AorusBackupArchive.magicV2.count)
        probe.closeFile()
        if Array(head) == AorusBackupArchive.magicV2 { return .notNeeded }
        guard Array(head) == AorusBackupArchive.magicV1 else { return .failed }

        let tmpURL = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(Self.archiveName + ".migrate")
        do {
            let reader = try AorusBackupArchive.LegacyReader(url: archiveURL, key: key, limits: archiveLimits)
            try AorusBackupArchive.write(to: tmpURL, key: key, limits: archiveLimits) { try reader.next() }
            try reader.finish()
            try commitArchive(from: tmpURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            return .failed
        }

        // The durable copy has to follow, or a reinstall would restore the v1 bytes from the
        // Keychain and the restore path would refuse them. A failure here is not fatal: the
        // migrated archive is on disk, and the Keychain still holds a coherent older copy.
        let meta = keychainMeta()
        let ids = meta?.accountIds
            ?? UserDefaults.standard.stringArray(forKey: metaIdsKey)
            ?? localAccountIds()
        _ = storeArchiveInKeychain(
            accountIds: ids,
            date: meta.map { Date(timeIntervalSince1970: $0.date) } ?? Date(),
            accountCount: meta?.accountCount ?? ids.count,
            accounts: meta?.accounts ?? []
        )
        return .migrated
    }

    // Reject path traversal — only `accounts-metadata` and `account-*` roots allowed.
    private func isSafeRelativePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") { return false }
        let comps = path.split(separator: "/").map(String.init)
        if comps.contains("..") || comps.contains(".") { return false }
        guard let first = comps.first else { return false }
        return first == "accounts-metadata" || first.hasPrefix("account-")
    }

    // MARK: - Restore phase 2: apply at launch

    // Called from AppDelegate immediately after `rootPath` is known and BEFORE
    // any postbox / account context is created.
    public static func applyPendingRestoreIfNeeded(rootPath: String) {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: pendingFlagKey), !rootPath.isEmpty else { return }
        let mergeIntoExisting = ud.bool(forKey: pendingMergeFlagKey)
        let selectedAccountId = ud.string(forKey: pendingSelectedAccountKey)
        // Clear the flag up-front — a restore must never loop and brick every launch.
        ud.set(false, forKey: pendingFlagKey)
        ud.set(false, forKey: pendingMergeFlagKey)
        ud.removeObject(forKey: pendingSelectedAccountKey)

        let fm = FileManager.default
        let staging = URL(fileURLWithPath: rootPath).appendingPathComponent(stagingName)
        guard fm.fileExists(atPath: staging.path),
              let staged = try? fm.contentsOfDirectory(atPath: staging.path),
              !staged.isEmpty else {
            try? fm.removeItem(at: staging)
            return
        }

        // Drop snapshots from earlier restores — keep only the one we make now,
        // otherwise old account data (incl. media caches) accumulates forever.
        if let rootEntries = try? fm.contentsOfDirectory(atPath: rootPath) {
            for name in rootEntries where name.hasPrefix(snapshotPrefix) {
                try? fm.removeItem(at: URL(fileURLWithPath: rootPath).appendingPathComponent(name))
            }
        }

        if mergeIntoExisting, let selectedAccountId {
            _ = applyPendingAccountMerge(
                rootPath: rootPath,
                staging: staging,
                accountId: selectedAccountId
            )
            return
        }

        // Snapshot whatever currently occupies those top-level slots, so a failed
        // or unwanted restore stays recoverable.
        let snapshot = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(snapshotPrefix + String(Int(Date().timeIntervalSince1970)))
        try? fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for name in staged {
            let current = URL(fileURLWithPath: rootPath).appendingPathComponent(name)
            if fm.fileExists(atPath: current.path) {
                try? fm.moveItem(at: current, to: snapshot.appendingPathComponent(name))
            }
        }

        var allMoved = true
        for name in staged {
            let src = staging.appendingPathComponent(name)
            let dst = URL(fileURLWithPath: rootPath).appendingPathComponent(name)
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                allMoved = false
            }
        }
        try? fm.removeItem(at: staging)

        if !allMoved {
            // Roll back from the snapshot.
            for name in staged {
                let dst = URL(fileURLWithPath: rootPath).appendingPathComponent(name)
                let snap = snapshot.appendingPathComponent(name)
                if fm.fileExists(atPath: snap.path) {
                    try? fm.removeItem(at: dst)
                    try? fm.moveItem(at: snap, to: dst)
                }
            }
        }
    }

    private static func selectCurrentAccount(in root: URL, accountId: String) -> Bool {
        let atomicState = root.appendingPathComponent("accounts-metadata/atomic-state")
        guard let data = try? Data(contentsOf: atomicState),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              record(in: object["records"], accountId: accountId) != nil else {
            return false
        }
        object["currentRecordId"] = accountId
        object.removeValue(forKey: "currentAuthRecord")
        guard JSONSerialization.isValidJSONObject(object),
              let updated = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        do {
            try updated.write(to: atomicState, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func record(in recordsValue: Any?, accountId: String) -> [String: Any]? {
        if let records = recordsValue as? [[String: Any]] {
            return records.first(where: { recordId($0) == accountId })
        }
        if let records = recordsValue as? [String: Any] {
            if let direct = records[accountId] as? [String: Any] {
                return direct
            }
            return records.values.compactMap { $0 as? [String: Any] }.first(where: { recordId($0) == accountId })
        }
        return nil
    }

    private static func recordId(_ record: [String: Any]) -> String? {
        if let value = record["id"] as? String {
            return value
        }
        if let value = record["id"] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func mergedAtomicStateData(live: URL, staged: URL, accountId: String) -> Data? {
        guard let liveData = try? Data(contentsOf: live),
              let stagedData = try? Data(contentsOf: staged),
              var liveObject = (try? JSONSerialization.jsonObject(with: liveData)) as? [String: Any],
              let stagedObject = (try? JSONSerialization.jsonObject(with: stagedData)) as? [String: Any],
              let stagedRecord = record(in: stagedObject["records"], accountId: accountId) else {
            return nil
        }

        if var records = liveObject["records"] as? [[String: Any]] {
            if !records.contains(where: { recordId($0) == accountId }) {
                records.append(stagedRecord)
            }
            liveObject["records"] = records
        } else if var records = liveObject["records"] as? [String: Any] {
            if record(in: records, accountId: accountId) == nil {
                records[accountId] = stagedRecord
            }
            liveObject["records"] = records
        } else {
            return nil
        }

        liveObject["currentRecordId"] = accountId
        liveObject.removeValue(forKey: "currentAuthRecord")
        guard JSONSerialization.isValidJSONObject(liveObject) else { return nil }
        return try? JSONSerialization.data(withJSONObject: liveObject)
    }

    @discardableResult
    private static func applyPendingAccountMerge(rootPath: String, staging: URL, accountId: String) -> Bool {
        guard Int64(accountId) != nil else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
        let fm = FileManager.default
        let liveAtomic = URL(fileURLWithPath: rootPath).appendingPathComponent("accounts-metadata/atomic-state")
        let stagedAtomic = staging.appendingPathComponent("accounts-metadata/atomic-state")
        let stagedAccount = staging.appendingPathComponent("account-" + accountId, isDirectory: true)
        let liveAccount = URL(fileURLWithPath: rootPath).appendingPathComponent("account-" + accountId, isDirectory: true)
        guard let mergedState = mergedAtomicStateData(live: liveAtomic, staged: stagedAtomic, accountId: accountId),
              fm.fileExists(atPath: stagedAccount.path) else {
            try? fm.removeItem(at: staging)
            return false
        }

        let snapshot = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(snapshotPrefix + String(Int(Date().timeIntervalSince1970)))
        let snapshotAtomic = snapshot.appendingPathComponent("accounts-metadata/atomic-state")
        do {
            try fm.createDirectory(at: snapshotAtomic.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: liveAtomic, to: snapshotAtomic)
        } catch {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: snapshot)
            return false
        }

        var movedAccount = false
        do {
            if !fm.fileExists(atPath: liveAccount.path) {
                try fm.moveItem(at: stagedAccount, to: liveAccount)
                movedAccount = true
            }
            try mergedState.write(to: liveAtomic, options: .atomic)
            try? fm.removeItem(at: staging)
            return true
        } catch {
            if movedAccount {
                try? fm.removeItem(at: liveAccount)
            }
            try? fm.removeItem(at: liveAtomic)
            try? fm.copyItem(at: snapshotAtomic, to: liveAtomic)
            try? fm.removeItem(at: staging)
            return false
        }
    }

    // MARK: - Delete

    public func deleteBackup() {
        try? FileManager.default.removeItem(at: archiveURL)
        deleteKey()
        deleteKeychainArchive()
        let ud = UserDefaults.standard
        ud.removeObject(forKey: metaDateKey)
        ud.removeObject(forKey: metaCountKey)
        ud.removeObject(forKey: metaSizeKey)
        ud.removeObject(forKey: metaIdsKey)
    }

    // MARK: - Durable Keychain archive (survives reinstall)

    // Generic Keychain data slot under our service, keyed by an account name.
    //
    // Updates in place. Deleting first and adding afterwards means that between the two calls
    // the slot holds nothing, and an add that fails leaves it that way permanently.
    private func keychainSet(_ account: String, _ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func keychainGet(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        hardenKeychainAccessibility(account)
        return data
    }

    private func hardenKeychainAccessibility(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let values: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        _ = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    }

    private func keychainDelete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func keychainMeta() -> KeychainBackupMeta? {
        guard let data = keychainGet(keychainMetaName) else { return nil }
        return try? JSONDecoder().decode(KeychainBackupMeta.self, from: data)
    }

    // Chunk item name for a generation. Generation 0 is the unsuffixed naming used before
    // generations existed, so an install that predates this still finds its chunks.
    private func keychainChunkName(generation: Int, index: Int) -> String {
        if generation <= 0 {
            return keychainChunkPrefix + String(index)
        }
        return keychainChunkPrefix + "g" + String(generation) + "_" + String(index)
    }

    private var maxKeychainChunks: Int {
        return Int(maxEncryptedArchiveSize) / keychainChunkSize + 1
    }

    // Stream the on-disk archive into chunked Keychain items + a metadata slot.
    //
    // The new chunks go to a new generation, next to the ones already there, and the metadata
    // item — a single Keychain write, and the only thing that names a generation — is the
    // commit. Only then is the previous generation removed. The old code erased every chunk
    // and the metadata *first*, so an error partway through, or the process going away, left
    // the user with no durable backup at all and no way back to the one they had.
    private func storeArchiveInKeychain(accountIds: [String], date: Date, accountCount: Int, accounts: [AccountRecordMeta]) -> Bool {
        let previous = keychainMeta()
        let generation = max(previous?.generation ?? 0, 0) + 1
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return false }
        defer { try? handle.close() }
        var index = 0
        var total: Int64 = 0
        while true {
            let chunk = handle.readData(ofLength: keychainChunkSize)
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            guard total <= Int64(maxEncryptedArchiveSize),
                  index <= maxKeychainChunks else {
                deleteKeychainChunks(generation: generation, count: index)
                return false
            }
            guard keychainSet(keychainChunkName(generation: generation, index: index), chunk) else {
                deleteKeychainChunks(generation: generation, count: index)
                return false
            }
            index += 1
        }
        let meta = KeychainBackupMeta(chunkCount: index, sizeBytes: total, date: date.timeIntervalSince1970, accountCount: accountCount, accountIds: accountIds, accounts: accounts.isEmpty ? nil : accounts, generation: generation)
        guard let metaData = try? JSONEncoder().encode(meta), keychainSet(keychainMetaName, metaData) else {
            deleteKeychainChunks(generation: generation, count: index)
            return false
        }
        // Past the commit point: the metadata names the new generation, so the old one is
        // dead weight. One generation further back covers a kill between commit and cleanup.
        if let previous {
            deleteKeychainChunks(generation: previous.generation ?? 0, count: previous.chunkCount)
        }
        if generation >= 3 {
            deleteKeychainChunks(generation: generation - 2, count: 0)
        }
        return true
    }

    // Rebuild the archive file from Keychain chunks when the sandbox copy is gone.
    private func materializeArchiveFromKeychainIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: archiveURL.path) else { return }
        guard let meta = keychainMeta(),
              meta.chunkCount > 0,
              meta.chunkCount <= Int(maxEncryptedArchiveSize) / keychainChunkSize + 1,
              meta.sizeBytes > 0,
              UInt64(meta.sizeBytes) <= maxEncryptedArchiveSize else { return }
        guard fm.createFile(atPath: archiveURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: archiveURL) else { return }
        var ok = true
        var written: Int64 = 0
        for i in 0 ..< meta.chunkCount {
            guard let chunk = keychainGet(keychainChunkName(generation: meta.generation ?? 0, index: i)),
                  !chunk.isEmpty,
                  chunk.count <= keychainChunkSize else { ok = false; break }
            written += Int64(chunk.count)
            guard written <= meta.sizeBytes else { ok = false; break }
            handle.write(chunk)
        }
        if written != meta.sizeBytes { ok = false }
        try? handle.close()
        if !ok {
            try? fm.removeItem(at: archiveURL)
        }
    }

    // Remove one generation's chunk items: the `count` the metadata recorded, then an
    // overscan that stops at the first name that is not there, so a previous, larger backup
    // cannot leave items behind and the scan stays bounded.
    private func deleteKeychainChunks(generation: Int, count: Int) {
        let maxChunks = maxKeychainChunks
        let recorded = min(max(count, 0), maxChunks)
        for i in 0 ..< recorded {
            keychainDelete(keychainChunkName(generation: generation, index: i))
        }
        var extra = recorded
        while extra < maxChunks,
              keychainGet(keychainChunkName(generation: generation, index: extra)) != nil {
            keychainDelete(keychainChunkName(generation: generation, index: extra))
            extra += 1
        }
    }

    // Used by deleteBackup(), where destroying everything is the point. Clears the current
    // generation, the one before it, and the unsuffixed pre-generation naming.
    private func deleteKeychainArchive() {
        let meta = keychainMeta()
        let generation = max(meta?.generation ?? 0, 0)
        deleteKeychainChunks(generation: generation, count: meta?.chunkCount ?? 0)
        if generation > 0 {
            deleteKeychainChunks(generation: generation - 1, count: 0)
            deleteKeychainChunks(generation: 0, count: 0)
        }
        keychainDelete(keychainMetaName)
    }

    // MARK: - Keychain (AES key)

    // The AES key is the one thing that makes every stored copy of the backup readable, so it
    // is never deleted to be rewritten: an unchanged key is left alone, and a changed one is
    // updated in place. The old delete-then-add lost the key outright whenever the add failed,
    // taking the archive on disk and every Keychain chunk of the previous backup with it.
    private func saveKey(_ key: SymmetricKey) -> Bool {
        if let existing = loadKey(), existing == key { return true }
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyName,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyName,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        hardenKeychainAccessibility(keychainKeyName)
        return SymmetricKey(data: data)
    }

    private func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyName,
        ]
        SecItemDelete(query as CFDictionary)
    }

}

// Backup-failure messages in the languages AorusGram speaks beyond Russian and English.
// Keyed by the English string, exactly like the tables in AorusGramUI and the
// subscription module; a key with no entry falls back to English.
private enum AccountBackupL10n {
    static let tables: [String: [String: String]] = [
        "it": [
            "Account data path is unavailable": "Il percorso dei dati degli account non è disponibile",
            "No account data available for backup": "Nessun dato account da salvare",
            "Backup is too large": "Il backup è troppo grande",
            "Failed to create backup file": "Impossibile creare il file di backup",
            "Data encryption failed": "Cifratura dei dati non riuscita",
            "Failed to save backup": "Impossibile salvare il backup",
            "Failed to save key in Keychain": "Impossibile salvare la chiave nel portachiavi",
            "Failed to save backup to Keychain": "Impossibile salvare il backup nel portachiavi",
            "No account selected to add": "Nessun account selezionato da aggiungere",
            "Backup not found": "Backup non trovato",
            "Failed to create restore folder": "Impossibile creare la cartella di ripristino",
            "Failed to open backup": "Impossibile aprire il backup",
            "Backup file is corrupted": "Il file di backup è danneggiato",
            "Backup decryption failed": "Decifratura del backup non riuscita",
            "The selected account is missing from the backup": "L'account selezionato non è presente nel backup",
            "The selected account data is missing": "Mancano i dati dell'account selezionato",
        ],
        "pl": [
            "Account data path is unavailable": "Ścieżka do danych kont jest niedostępna",
            "No account data available for backup": "Brak danych kont do kopii",
            "Backup is too large": "Kopia jest za duża",
            "Failed to create backup file": "Nie udało się utworzyć pliku kopii",
            "Data encryption failed": "Błąd szyfrowania danych",
            "Failed to save backup": "Nie udało się zapisać kopii",
            "Failed to save key in Keychain": "Nie udało się zapisać klucza w Keychainie",
            "Failed to save backup to Keychain": "Nie udało się zapisać kopii w Keychainie",
            "No account selected to add": "Nie wybrano konta do dodania",
            "Backup not found": "Nie znaleziono kopii",
            "Failed to create restore folder": "Nie udało się utworzyć folderu przywracania",
            "Failed to open backup": "Nie udało się otworzyć kopii",
            "Backup file is corrupted": "Plik kopii jest uszkodzony",
            "Backup decryption failed": "Błąd odszyfrowania kopii",
            "The selected account is missing from the backup": "Wybranego konta nie ma w kopii",
            "The selected account data is missing": "Brakuje danych wybranego konta",
        ],
        "nl": [
            "Account data path is unavailable": "Het pad naar de accountgegevens is niet beschikbaar",
            "No account data available for backup": "Geen accountgegevens om te back-uppen",
            "Backup is too large": "De back-up is te groot",
            "Failed to create backup file": "Kon het back-upbestand niet aanmaken",
            "Data encryption failed": "Versleutelen van de gegevens is mislukt",
            "Failed to save backup": "Kon de back-up niet bewaren",
            "Failed to save key in Keychain": "Kon de sleutel niet in de sleutelhanger bewaren",
            "Failed to save backup to Keychain": "Kon de back-up niet in de sleutelhanger bewaren",
            "No account selected to add": "Geen account gekozen om toe te voegen",
            "Backup not found": "Back-up niet gevonden",
            "Failed to create restore folder": "Kon de herstelmap niet aanmaken",
            "Failed to open backup": "Kon de back-up niet openen",
            "Backup file is corrupted": "Het back-upbestand is beschadigd",
            "Backup decryption failed": "Ontsleutelen van de back-up is mislukt",
            "The selected account is missing from the backup": "Het gekozen account ontbreekt in de back-up",
            "The selected account data is missing": "De gegevens van het gekozen account ontbreken",
        ],
        "ca": [
            "Account data path is unavailable": "El camí de les dades dels comptes no està disponible",
            "No account data available for backup": "No hi ha dades de comptes per desar",
            "Backup is too large": "La còpia és massa gran",
            "Failed to create backup file": "No s'ha pogut crear el fitxer de la còpia",
            "Data encryption failed": "Ha fallat el xifratge de les dades",
            "Failed to save backup": "No s'ha pogut desar la còpia",
            "Failed to save key in Keychain": "No s'ha pogut desar la clau al clauer",
            "Failed to save backup to Keychain": "No s'ha pogut desar la còpia al clauer",
            "No account selected to add": "No s'ha triat cap compte per afegir",
            "Backup not found": "No s'ha trobat la còpia",
            "Failed to create restore folder": "No s'ha pogut crear la carpeta de restauració",
            "Failed to open backup": "No s'ha pogut obrir la còpia",
            "Backup file is corrupted": "El fitxer de la còpia està malmès",
            "Backup decryption failed": "Ha fallat el desxifratge de la còpia",
            "The selected account is missing from the backup": "El compte triat no és a la còpia",
            "The selected account data is missing": "Falten les dades del compte triat",
        ],
        "id": [
            "Account data path is unavailable": "Jalur data akun tidak tersedia",
            "No account data available for backup": "Tidak ada data akun untuk dicadangkan",
            "Backup is too large": "Cadangan terlalu besar",
            "Failed to create backup file": "Berkas cadangan tidak dapat dibuat",
            "Data encryption failed": "Enkripsi data gagal",
            "Failed to save backup": "Cadangan tidak dapat disimpan",
            "Failed to save key in Keychain": "Kunci tidak dapat disimpan di Keychain",
            "Failed to save backup to Keychain": "Cadangan tidak dapat disimpan di Keychain",
            "No account selected to add": "Tidak ada akun yang dipilih untuk ditambahkan",
            "Backup not found": "Cadangan tidak ditemukan",
            "Failed to create restore folder": "Folder pemulihan tidak dapat dibuat",
            "Failed to open backup": "Cadangan tidak dapat dibuka",
            "Backup file is corrupted": "Berkas cadangan rusak",
            "Backup decryption failed": "Dekripsi cadangan gagal",
            "The selected account is missing from the backup": "Akun yang dipilih tidak ada di cadangan",
            "The selected account data is missing": "Data akun yang dipilih tidak ada",
        ],
        "ms": [
            "Account data path is unavailable": "Laluan data akaun tidak tersedia",
            "No account data available for backup": "Tiada data akaun untuk disandarkan",
            "Backup is too large": "Sandaran terlalu besar",
            "Failed to create backup file": "Fail sandaran tidak dapat dicipta",
            "Data encryption failed": "Penyulitan data gagal",
            "Failed to save backup": "Sandaran tidak dapat disimpan",
            "Failed to save key in Keychain": "Kunci tidak dapat disimpan dalam Keychain",
            "Failed to save backup to Keychain": "Sandaran tidak dapat disimpan dalam Keychain",
            "No account selected to add": "Tiada akaun dipilih untuk ditambah",
            "Backup not found": "Sandaran tidak dijumpai",
            "Failed to create restore folder": "Folder pemulihan tidak dapat dicipta",
            "Failed to open backup": "Sandaran tidak dapat dibuka",
            "Backup file is corrupted": "Fail sandaran rosak",
            "Backup decryption failed": "Nyahsulit sandaran gagal",
            "The selected account is missing from the backup": "Akaun yang dipilih tiada dalam sandaran",
            "The selected account data is missing": "Data akaun yang dipilih tiada",
        ],
        "be": [
            "Account data path is unavailable": "Шлях да даных акаўнтаў недаступны",
            "No account data available for backup": "Няма даных акаўнтаў для рэзервовай копіі",
            "Backup is too large": "Рэзервовая копія занадта вялікая",
            "Failed to create backup file": "Не ўдалося стварыць файл копіі",
            "Data encryption failed": "Памылка шыфравання даных",
            "Failed to save backup": "Не ўдалося захаваць копію",
            "Failed to save key in Keychain": "Не ўдалося захаваць ключ у Keychain",
            "Failed to save backup to Keychain": "Не ўдалося захаваць копію ў Keychain",
            "No account selected to add": "Не выбраны акаўнт для дадання",
            "Backup not found": "Копія не знойдзена",
            "Failed to create restore folder": "Не ўдалося стварыць папку аднаўлення",
            "Failed to open backup": "Не ўдалося адкрыць копію",
            "Backup file is corrupted": "Файл копіі пашкоджаны",
            "Backup decryption failed": "Памылка расшыфроўкі копіі",
            "The selected account is missing from the backup": "Выбраны акаўнт адсутнічае ў копіі",
            "The selected account data is missing": "Даныя выбранага акаўнта адсутнічаюць",
        ],
        "uz": [
            "Account data path is unavailable": "Hisob ma’lumotlari yo‘li mavjud emas",
            "No account data available for backup": "Zaxiralash uchun hisob ma’lumotlari yo‘q",
            "Backup is too large": "Zaxira juda katta",
            "Failed to create backup file": "Zaxira faylini yaratib bo‘lmadi",
            "Data encryption failed": "Ma’lumotlarni shifrlab bo‘lmadi",
            "Failed to save backup": "Zaxirani saqlab bo‘lmadi",
            "Failed to save key in Keychain": "Kalitni Keychain’ga saqlab bo‘lmadi",
            "Failed to save backup to Keychain": "Zaxirani Keychain’ga saqlab bo‘lmadi",
            "No account selected to add": "Qo‘shish uchun hisob tanlanmadi",
            "Backup not found": "Zaxira topilmadi",
            "Failed to create restore folder": "Tiklash papkasini yaratib bo‘lmadi",
            "Failed to open backup": "Zaxirani ochib bo‘lmadi",
            "Backup file is corrupted": "Zaxira fayli buzilgan",
            "Backup decryption failed": "Zaxirani shifrdan chiqarib bo‘lmadi",
            "The selected account is missing from the backup": "Tanlangan hisob zaxirada yo‘q",
            "The selected account data is missing": "Tanlangan hisob ma’lumotlari yo‘q",
        ],
        "ko": [
            "Account data path is unavailable": "계정 데이터 경로를 사용할 수 없습니다",
            "No account data available for backup": "백업할 계정 데이터가 없습니다",
            "Backup is too large": "백업이 너무 큽니다",
            "Failed to create backup file": "백업 파일을 만들지 못했습니다",
            "Data encryption failed": "데이터 암호화에 실패했습니다",
            "Failed to save backup": "백업을 저장하지 못했습니다",
            "Failed to save key in Keychain": "키를 키체인에 저장하지 못했습니다",
            "Failed to save backup to Keychain": "백업을 키체인에 저장하지 못했습니다",
            "No account selected to add": "추가할 계정이 선택되지 않았습니다",
            "Backup not found": "백업을 찾을 수 없습니다",
            "Failed to create restore folder": "복원 폴더를 만들지 못했습니다",
            "Failed to open backup": "백업을 열지 못했습니다",
            "Backup file is corrupted": "백업 파일이 손상되었습니다",
            "Backup decryption failed": "백업 복호화에 실패했습니다",
            "The selected account is missing from the backup": "선택한 계정이 백업에 없습니다",
            "The selected account data is missing": "선택한 계정의 데이터가 없습니다",
        ],
        "ar": [
            "Account data path is unavailable": "مسار بيانات الحسابات غير متاح",
            "No account data available for backup": "لا توجد بيانات حسابات للنسخ الاحتياطي",
            "Backup is too large": "النسخة الاحتياطية كبيرة جدًا",
            "Failed to create backup file": "تعذّر إنشاء ملف النسخة الاحتياطية",
            "Data encryption failed": "فشل تشفير البيانات",
            "Failed to save backup": "تعذّر حفظ النسخة الاحتياطية",
            "Failed to save key in Keychain": "تعذّر حفظ المفتاح في Keychain",
            "Failed to save backup to Keychain": "تعذّر حفظ النسخة الاحتياطية في Keychain",
            "No account selected to add": "لم يُحدَّد حساب لإضافته",
            "Backup not found": "النسخة الاحتياطية غير موجودة",
            "Failed to create restore folder": "تعذّر إنشاء مجلد الاستعادة",
            "Failed to open backup": "تعذّر فتح النسخة الاحتياطية",
            "Backup file is corrupted": "ملف النسخة الاحتياطية تالف",
            "Backup decryption failed": "فشل فك تشفير النسخة الاحتياطية",
            "The selected account is missing from the backup": "الحساب المحدد غير موجود في النسخة الاحتياطية",
            "The selected account data is missing": "بيانات الحساب المحدد غير موجودة",
        ],
        "fa": [
            "Account data path is unavailable": "مسیر داده‌های حساب‌ها در دسترس نیست",
            "No account data available for backup": "داده‌ای از حساب‌ها برای پشتیبان‌گیری نیست",
            "Backup is too large": "پشتیبان خیلی بزرگ است",
            "Failed to create backup file": "ساخت فایل پشتیبان ممکن نشد",
            "Data encryption failed": "رمزگذاری داده‌ها ناموفق بود",
            "Failed to save backup": "ذخیرهٔ پشتیبان ممکن نشد",
            "Failed to save key in Keychain": "ذخیرهٔ کلید در Keychain ممکن نشد",
            "Failed to save backup to Keychain": "ذخیرهٔ پشتیبان در Keychain ممکن نشد",
            "No account selected to add": "حسابی برای افزودن انتخاب نشد",
            "Backup not found": "پشتیبان یافت نشد",
            "Failed to create restore folder": "ساخت پوشهٔ بازیابی ممکن نشد",
            "Failed to open backup": "باز کردن پشتیبان ممکن نشد",
            "Backup file is corrupted": "فایل پشتیبان خراب است",
            "Backup decryption failed": "رمزگشایی پشتیبان ناموفق بود",
            "The selected account is missing from the backup": "حساب انتخاب‌شده در پشتیبان نیست",
            "The selected account data is missing": "داده‌های حساب انتخاب‌شده موجود نیست",
        ],
        "kk": [
            "Account data path is unavailable": "Аккаунт деректерінің жолы қолжетімсіз",
            "No account data available for backup": "Көшірме жасауға аккаунт деректері жоқ",
            "Backup is too large": "Көшірме тым үлкен",
            "Failed to create backup file": "Көшірме файлын жасау мүмкін болмады",
            "Data encryption failed": "Деректерді шифрлау мүмкін болмады",
            "Failed to save backup": "Көшірмені сақтау мүмкін болмады",
            "Failed to save key in Keychain": "Кілтті Keychain-ге сақтау мүмкін болмады",
            "Failed to save backup to Keychain": "Көшірмені Keychain-ге сақтау мүмкін болмады",
            "No account selected to add": "Қосу үшін аккаунт таңдалмаған",
            "Backup not found": "Көшірме табылмады",
            "Failed to create restore folder": "Қалпына келтіру қалтасын жасау мүмкін болмады",
            "Failed to open backup": "Көшірмені ашу мүмкін болмады",
            "Backup file is corrupted": "Көшірме файлы бүлінген",
            "Backup decryption failed": "Көшірмені шифрдан шығару мүмкін болмады",
            "The selected account is missing from the backup": "Таңдалған аккаунт көшірмеде жоқ",
            "The selected account data is missing": "Таңдалған аккаунт деректері жоқ",
        ],
        "zh-hans": [
            "Account data path is unavailable": "账号数据路径不可用",
            "No account data available for backup": "没有可备份的账号数据",
            "Backup is too large": "备份文件过大",
            "Failed to create backup file": "无法创建备份文件",
            "Data encryption failed": "数据加密失败",
            "Failed to save backup": "无法保存备份",
            "Failed to save key in Keychain": "无法在钥匙串中保存密钥",
            "Failed to save backup to Keychain": "无法将备份保存到钥匙串",
            "No account selected to add": "未选择要添加的账号",
            "Backup not found": "未找到备份",
            "Failed to create restore folder": "无法创建恢复文件夹",
            "Failed to open backup": "无法打开备份",
            "Backup file is corrupted": "备份文件已损坏",
            "Backup decryption failed": "备份解密失败",
            "The selected account is missing from the backup": "备份中没有所选账号",
            "The selected account data is missing": "所选账号的数据缺失",
        ],
        "zh-hant": [
            "Account data path is unavailable": "帳號資料路徑不可用",
            "No account data available for backup": "沒有可備份的帳號資料",
            "Backup is too large": "備份檔案過大",
            "Failed to create backup file": "無法建立備份檔案",
            "Data encryption failed": "資料加密失敗",
            "Failed to save backup": "無法儲存備份",
            "Failed to save key in Keychain": "無法在鑰匙圈中儲存金鑰",
            "Failed to save backup to Keychain": "無法將備份儲存到鑰匙圈",
            "No account selected to add": "未選擇要新增的帳號",
            "Backup not found": "未找到備份",
            "Failed to create restore folder": "無法建立恢復資料夾",
            "Failed to open backup": "無法開啟備份",
            "Backup file is corrupted": "備份檔案已損壞",
            "Backup decryption failed": "備份解密失敗",
            "The selected account is missing from the backup": "備份中沒有所選帳號",
            "The selected account data is missing": "所選帳號的資料缺失",
        ],
        "ja": [
            "Account data path is unavailable": "アカウントデータのパスを利用できません",
            "No account data available for backup": "バックアップできるアカウントデータがありません",
            "Backup is too large": "バックアップが大きすぎます",
            "Failed to create backup file": "バックアップファイルを作成できませんでした",
            "Data encryption failed": "データの暗号化に失敗しました",
            "Failed to save backup": "バックアップを保存できませんでした",
            "Failed to save key in Keychain": "キーチェーンに鍵を保存できませんでした",
            "Failed to save backup to Keychain": "バックアップをキーチェーンに保存できませんでした",
            "No account selected to add": "追加するアカウントが選択されていません",
            "Backup not found": "バックアップが見つかりません",
            "Failed to create restore folder": "復元用のフォルダを作成できませんでした",
            "Failed to open backup": "バックアップを開けませんでした",
            "Backup file is corrupted": "バックアップファイルが壊れています",
            "Backup decryption failed": "バックアップの復号に失敗しました",
            "The selected account is missing from the backup": "選択したアカウントがバックアップにありません",
            "The selected account data is missing": "選択したアカウントのデータがありません",
        ],
        "fi": [
            "Account data path is unavailable": "Tilin datapolku ei ole käytettävissä",
            "No account data available for backup": "Varmuuskopioitavaa tilidataa ei ole",
            "Backup is too large": "Varmuuskopio on liian suuri",
            "Failed to create backup file": "Varmuuskopiotiedoston luonti epäonnistui",
            "Data encryption failed": "Tietojen salaus epäonnistui",
            "Failed to save backup": "Varmuuskopion tallennus epäonnistui",
            "Failed to save key in Keychain": "Avaimen tallennus avainnippuun epäonnistui",
            "Failed to save backup to Keychain": "Varmuuskopion tallennus avainnippuun epäonnistui",
            "No account selected to add": "Lisättävää tiliä ei ole valittu",
            "Backup not found": "Varmuuskopiota ei löytynyt",
            "Failed to create restore folder": "Palautuskansion luonti epäonnistui",
            "Failed to open backup": "Varmuuskopion avaaminen epäonnistui",
            "Backup file is corrupted": "Varmuuskopiotiedosto on vioittunut",
            "Backup decryption failed": "Varmuuskopion purku epäonnistui",
            "The selected account is missing from the backup": "Valittua tiliä ei ole varmuuskopiossa",
            "The selected account data is missing": "Valitun tilin tiedot puuttuvat",
        ],
        "he": [
            "Account data path is unavailable": "נתיב נתוני החשבון אינו זמין",
            "No account data available for backup": "אין נתוני חשבון זמינים לגיבוי",
            "Backup is too large": "הגיבוי גדול מדי",
            "Failed to create backup file": "יצירת קובץ הגיבוי נכשלה",
            "Data encryption failed": "הצפנת הנתונים נכשלה",
            "Failed to save backup": "שמירת הגיבוי נכשלה",
            "Failed to save key in Keychain": "שמירת המפתח בצרור המפתחות נכשלה",
            "Failed to save backup to Keychain": "שמירת הגיבוי בצרור המפתחות נכשלה",
            "No account selected to add": "לא נבחר חשבון להוספה",
            "Backup not found": "הגיבוי לא נמצא",
            "Failed to create restore folder": "יצירת תיקיית השחזור נכשלה",
            "Failed to open backup": "פתיחת הגיבוי נכשלה",
            "Backup file is corrupted": "קובץ הגיבוי פגום",
            "Backup decryption failed": "פענוח הגיבוי נכשל",
            "The selected account is missing from the backup": "החשבון שנבחר חסר בגיבוי",
            "The selected account data is missing": "נתוני החשבון שנבחר חסרים",
        ],
        "hr": [
            "Account data path is unavailable": "Putanja podataka računa nije dostupna",
            "No account data available for backup": "Nema podataka računa za sigurnosnu kopiju",
            "Backup is too large": "Sigurnosna kopija je prevelika",
            "Failed to create backup file": "Nije bilo moguće izraditi datoteku sigurnosne kopije",
            "Data encryption failed": "Šifriranje podataka nije uspjelo",
            "Failed to save backup": "Nije bilo moguće spremiti sigurnosnu kopiju",
            "Failed to save key in Keychain": "Nije bilo moguće spremiti ključ u Keychain",
            "Failed to save backup to Keychain": "Nije bilo moguće spremiti sigurnosnu kopiju u Keychain",
            "No account selected to add": "Nije odabran račun za dodavanje",
            "Backup not found": "Sigurnosna kopija nije pronađena",
            "Failed to create restore folder": "Nije bilo moguće izraditi mapu za vraćanje",
            "Failed to open backup": "Nije bilo moguće otvoriti sigurnosnu kopiju",
            "Backup file is corrupted": "Datoteka sigurnosne kopije je oštećena",
            "Backup decryption failed": "Dešifriranje sigurnosne kopije nije uspjelo",
            "The selected account is missing from the backup": "Odabrani račun nedostaje u sigurnosnoj kopiji",
            "The selected account data is missing": "Podaci odabranog računa nedostaju",
        ],
        "sr": [
            "Account data path is unavailable": "Путања података налога није доступна",
            "No account data available for backup": "Нема података налога за резервну копију",
            "Backup is too large": "Резервна копија је превелика",
            "Failed to create backup file": "Није било могуће направити датотеку резервне копије",
            "Data encryption failed": "Шифровање података није успело",
            "Failed to save backup": "Није било могуће сачувати резервну копију",
            "Failed to save key in Keychain": "Није било могуће сачувати кључ у Keychain",
            "Failed to save backup to Keychain": "Није било могуће сачувати резервну копију у Keychain",
            "No account selected to add": "Није изабран налог за додавање",
            "Backup not found": "Резервна копија није пронађена",
            "Failed to create restore folder": "Није било могуће направити фасциклу за враћање",
            "Failed to open backup": "Није било могуће отворити резервну копију",
            "Backup file is corrupted": "Датотека резервне копије је оштећена",
            "Backup decryption failed": "Дешифровање резервне копије није успело",
            "The selected account is missing from the backup": "Изабрани налог недостаје у резервној копији",
            "The selected account data is missing": "Подаци изабраног налога недостају",
        ],
        "cs": [
            "Account data path is unavailable": "Cesta k datům účtu není dostupná",
            "No account data available for backup": "K záloze nejsou k dispozici žádná data účtu",
            "Backup is too large": "Záloha je příliš velká",
            "Failed to create backup file": "Soubor zálohy se nepodařilo vytvořit",
            "Data encryption failed": "Šifrování dat se nezdařilo",
            "Failed to save backup": "Zálohu se nepodařilo uložit",
            "Failed to save key in Keychain": "Klíč se nepodařilo uložit do Klíčenky",
            "Failed to save backup to Keychain": "Zálohu se nepodařilo uložit do Klíčenky",
            "No account selected to add": "Není vybrán žádný účet k přidání",
            "Backup not found": "Záloha nebyla nalezena",
            "Failed to create restore folder": "Složku pro obnovení se nepodařilo vytvořit",
            "Failed to open backup": "Zálohu se nepodařilo otevřít",
            "Backup file is corrupted": "Soubor zálohy je poškozen",
            "Backup decryption failed": "Dešifrování zálohy se nezdařilo",
            "The selected account is missing from the backup": "Vybraný účet v záloze chybí",
            "The selected account data is missing": "Data vybraného účtu chybí",
        ],
        "sk": [
            "Account data path is unavailable": "Cesta k údajom účtu nie je dostupná",
            "No account data available for backup": "Na zálohu nie sú k dispozícii žiadne údaje účtu",
            "Backup is too large": "Záloha je príliš veľká",
            "Failed to create backup file": "Súbor zálohy sa nepodarilo vytvoriť",
            "Data encryption failed": "Šifrovanie údajov zlyhalo",
            "Failed to save backup": "Zálohu sa nepodarilo uložiť",
            "Failed to save key in Keychain": "Kľúč sa nepodarilo uložiť do Zväzku kľúčov",
            "Failed to save backup to Keychain": "Zálohu sa nepodarilo uložiť do Zväzku kľúčov",
            "No account selected to add": "Nie je vybraný žiadny účet na pridanie",
            "Backup not found": "Záloha sa nenašla",
            "Failed to create restore folder": "Priečinok na obnovenie sa nepodarilo vytvoriť",
            "Failed to open backup": "Zálohu sa nepodarilo otvoriť",
            "Backup file is corrupted": "Súbor zálohy je poškodený",
            "Backup decryption failed": "Dešifrovanie zálohy zlyhalo",
            "The selected account is missing from the backup": "Vybraný účet v zálohe chýba",
            "The selected account data is missing": "Údaje vybraného účtu chýbajú",
        ],
        "ro": [
            "Account data path is unavailable": "Calea către datele contului nu este disponibilă",
            "No account data available for backup": "Nu există date de cont pentru copia de rezervă",
            "Backup is too large": "Copia de rezervă este prea mare",
            "Failed to create backup file": "Fișierul copiei de rezervă nu a putut fi creat",
            "Data encryption failed": "Criptarea datelor a eșuat",
            "Failed to save backup": "Copia de rezervă nu a putut fi salvată",
            "Failed to save key in Keychain": "Cheia nu a putut fi salvată în Keychain",
            "Failed to save backup to Keychain": "Copia de rezervă nu a putut fi salvată în Keychain",
            "No account selected to add": "Niciun cont selectat pentru adăugare",
            "Backup not found": "Copia de rezervă nu a fost găsită",
            "Failed to create restore folder": "Folderul de restaurare nu a putut fi creat",
            "Failed to open backup": "Copia de rezervă nu a putut fi deschisă",
            "Backup file is corrupted": "Fișierul copiei de rezervă este deteriorat",
            "Backup decryption failed": "Decriptarea copiei de rezervă a eșuat",
            "The selected account is missing from the backup": "Contul selectat lipsește din copia de rezervă",
            "The selected account data is missing": "Datele contului selectat lipsesc",
        ],
        "hu": [
            "Account data path is unavailable": "A fiókadatok elérési útja nem érhető el",
            "No account data available for backup": "Nincs menthető fiókadat",
            "Backup is too large": "A biztonsági mentés túl nagy",
            "Failed to create backup file": "A mentésfájlt nem sikerült létrehozni",
            "Data encryption failed": "Az adatok titkosítása nem sikerült",
            "Failed to save backup": "A mentést nem sikerült elmenteni",
            "Failed to save key in Keychain": "A kulcsot nem sikerült a Kulcskarikára menteni",
            "Failed to save backup to Keychain": "A mentést nem sikerült a Kulcskarikára menteni",
            "No account selected to add": "Nincs kiválasztva hozzáadandó fiók",
            "Backup not found": "A mentés nem található",
            "Failed to create restore folder": "A visszaállítási mappát nem sikerült létrehozni",
            "Failed to open backup": "A mentést nem sikerült megnyitni",
            "Backup file is corrupted": "A mentésfájl sérült",
            "Backup decryption failed": "A mentés visszafejtése nem sikerült",
            "The selected account is missing from the backup": "A kiválasztott fiók hiányzik a mentésből",
            "The selected account data is missing": "A kiválasztott fiók adatai hiányoznak",
        ],
        "nb": [
            "Account data path is unavailable": "Banen til kontodataene er utilgjengelig",
            "No account data available for backup": "Ingen kontodata tilgjengelig for sikkerhetskopiering",
            "Backup is too large": "Sikkerhetskopien er for stor",
            "Failed to create backup file": "Kunne ikke opprette sikkerhetskopifilen",
            "Data encryption failed": "Krypteringen av dataene mislyktes",
            "Failed to save backup": "Kunne ikke lagre sikkerhetskopien",
            "Failed to save key in Keychain": "Kunne ikke lagre nøkkelen i nøkkelringen",
            "Failed to save backup to Keychain": "Kunne ikke lagre sikkerhetskopien i nøkkelringen",
            "No account selected to add": "Ingen konto er valgt for å legges til",
            "Backup not found": "Fant ikke sikkerhetskopien",
            "Failed to create restore folder": "Kunne ikke opprette gjenopprettingsmappen",
            "Failed to open backup": "Kunne ikke åpne sikkerhetskopien",
            "Backup file is corrupted": "Sikkerhetskopifilen er skadet",
            "Backup decryption failed": "Dekrypteringen av sikkerhetskopien mislyktes",
            "The selected account is missing from the backup": "Den valgte kontoen mangler i sikkerhetskopien",
            "The selected account data is missing": "Dataene til den valgte kontoen mangler",
        ],
        "sv": [
            "Account data path is unavailable": "Sökvägen till kontouppgifterna är inte tillgänglig",
            "No account data available for backup": "Det finns inga kontouppgifter att säkerhetskopiera",
            "Backup is too large": "Säkerhetskopian är för stor",
            "Failed to create backup file": "Det gick inte att skapa säkerhetskopiefilen",
            "Data encryption failed": "Krypteringen av uppgifterna misslyckades",
            "Failed to save backup": "Det gick inte att spara säkerhetskopian",
            "Failed to save key in Keychain": "Det gick inte att spara nyckeln i nyckelringen",
            "Failed to save backup to Keychain": "Det gick inte att spara säkerhetskopian i nyckelringen",
            "No account selected to add": "Inget konto har valts att lägga till",
            "Backup not found": "Säkerhetskopian hittades inte",
            "Failed to create restore folder": "Det gick inte att skapa återställningsmappen",
            "Failed to open backup": "Det gick inte att öppna säkerhetskopian",
            "Backup file is corrupted": "Säkerhetskopiefilen är skadad",
            "Backup decryption failed": "Dekrypteringen av säkerhetskopian misslyckades",
            "The selected account is missing from the backup": "Det valda kontot saknas i säkerhetskopian",
            "The selected account data is missing": "Uppgifterna för det valda kontot saknas",
        ],
        "vi": [
            "Account data path is unavailable": "Không truy cập được đường dẫn dữ liệu tài khoản",
            "No account data available for backup": "Không có dữ liệu tài khoản để sao lưu",
            "Backup is too large": "Bản sao lưu quá lớn",
            "Failed to create backup file": "Không thể tạo tệp sao lưu",
            "Data encryption failed": "Mã hóa dữ liệu không thành công",
            "Failed to save backup": "Không thể lưu bản sao lưu",
            "Failed to save key in Keychain": "Không thể lưu khóa vào Keychain",
            "Failed to save backup to Keychain": "Không thể lưu bản sao lưu vào Keychain",
            "No account selected to add": "Chưa chọn tài khoản để thêm",
            "Backup not found": "Không tìm thấy bản sao lưu",
            "Failed to create restore folder": "Không thể tạo thư mục khôi phục",
            "Failed to open backup": "Không thể mở bản sao lưu",
            "Backup file is corrupted": "Tệp sao lưu bị hỏng",
            "Backup decryption failed": "Giải mã bản sao lưu không thành công",
            "The selected account is missing from the backup": "Bản sao lưu không có tài khoản đã chọn",
            "The selected account data is missing": "Thiếu dữ liệu của tài khoản đã chọn",
        ],
        "uk": [
            "Account data path is unavailable": "Шлях до даних акаунтів недоступний",
            "No account data available for backup": "Немає даних акаунтів для резервної копії",
            "Backup is too large": "Резервна копія завелика",
            "Failed to create backup file": "Не вдалося створити файл резервної копії",
            "Data encryption failed": "Помилка шифрування даних",
            "Failed to save backup": "Не вдалося зберегти резервну копію",
            "Failed to save key in Keychain": "Не вдалося зберегти ключ у Keychain",
            "Failed to save backup to Keychain": "Не вдалося зберегти резервну копію в Keychain",
            "No account selected to add": "Не вибрано акаунт для додавання",
            "Backup not found": "Резервну копію не знайдено",
            "Failed to create restore folder": "Не вдалося створити папку відновлення",
            "Failed to open backup": "Не вдалося відкрити резервну копію",
            "Backup file is corrupted": "Файл резервної копії пошкоджено",
            "Backup decryption failed": "Помилка розшифрування резервної копії",
            "The selected account is missing from the backup": "Акаунт відсутній у резервній копії",
            "The selected account data is missing": "Дані вибраного акаунта відсутні",
        ],
        "es": [
            "Account data path is unavailable": "La ruta de datos de las cuentas no está disponible",
            "No account data available for backup": "No hay datos de cuentas para la copia",
            "Backup is too large": "La copia es demasiado grande",
            "Failed to create backup file": "No se pudo crear el archivo de la copia",
            "Data encryption failed": "Fallo al cifrar los datos",
            "Failed to save backup": "No se pudo guardar la copia",
            "Failed to save key in Keychain": "No se pudo guardar la clave en el Keychain",
            "Failed to save backup to Keychain": "No se pudo guardar la copia en el Keychain",
            "No account selected to add": "No se ha elegido ninguna cuenta para añadir",
            "Backup not found": "No se encontró la copia",
            "Failed to create restore folder": "No se pudo crear la carpeta de restauración",
            "Failed to open backup": "No se pudo abrir la copia",
            "Backup file is corrupted": "El archivo de la copia está dañado",
            "Backup decryption failed": "Fallo al descifrar la copia",
            "The selected account is missing from the backup": "La cuenta elegida no está en la copia",
            "The selected account data is missing": "Faltan los datos de la cuenta elegida",
        ],
        "pt": [
            "Account data path is unavailable": "O caminho dos dados das contas está indisponível",
            "No account data available for backup": "Não há dados de contas para o backup",
            "Backup is too large": "O backup é grande demais",
            "Failed to create backup file": "Não foi possível criar o arquivo de backup",
            "Data encryption failed": "Falha ao criptografar os dados",
            "Failed to save backup": "Não foi possível salvar o backup",
            "Failed to save key in Keychain": "Não foi possível salvar a chave no Keychain",
            "Failed to save backup to Keychain": "Não foi possível salvar o backup no Keychain",
            "No account selected to add": "Nenhuma conta escolhida para adicionar",
            "Backup not found": "Backup não encontrado",
            "Failed to create restore folder": "Não foi possível criar a pasta de restauração",
            "Failed to open backup": "Não foi possível abrir o backup",
            "Backup file is corrupted": "O arquivo de backup está corrompido",
            "Backup decryption failed": "Falha ao descriptografar o backup",
            "The selected account is missing from the backup": "A conta escolhida não está no backup",
            "The selected account data is missing": "Faltam os dados da conta escolhida",
        ],
        "de": [
            "Account data path is unavailable": "Der Pfad zu den Kontodaten ist nicht verfügbar",
            "No account data available for backup": "Keine Kontodaten für ein Backup vorhanden",
            "Backup is too large": "Das Backup ist zu groß",
            "Failed to create backup file": "Die Backup-Datei konnte nicht erstellt werden",
            "Data encryption failed": "Die Daten konnten nicht verschlüsselt werden",
            "Failed to save backup": "Das Backup konnte nicht gesichert werden",
            "Failed to save key in Keychain": "Der Schlüssel konnte nicht im Schlüsselbund gesichert werden",
            "Failed to save backup to Keychain": "Das Backup konnte nicht im Schlüsselbund gesichert werden",
            "No account selected to add": "Es wurde kein Konto zum Hinzufügen gewählt",
            "Backup not found": "Kein Backup gefunden",
            "Failed to create restore folder": "Der Wiederherstellungsordner konnte nicht erstellt werden",
            "Failed to open backup": "Das Backup konnte nicht geöffnet werden",
            "Backup file is corrupted": "Die Backup-Datei ist beschädigt",
            "Backup decryption failed": "Das Backup konnte nicht entschlüsselt werden",
            "The selected account is missing from the backup": "Das gewählte Konto fehlt im Backup",
            "The selected account data is missing": "Die Daten des gewählten Kontos fehlen",
        ],
        "fr": [
            "Account data path is unavailable": "Le chemin des données des comptes est indisponible",
            "No account data available for backup": "Aucune donnée de compte à sauvegarder",
            "Backup is too large": "La sauvegarde est trop volumineuse",
            "Failed to create backup file": "Impossible de créer le fichier de sauvegarde",
            "Data encryption failed": "Échec du chiffrement des données",
            "Failed to save backup": "Impossible d’enregistrer la sauvegarde",
            "Failed to save key in Keychain": "Impossible d’enregistrer la clé dans le trousseau",
            "Failed to save backup to Keychain": "Impossible d’enregistrer la sauvegarde dans le trousseau",
            "No account selected to add": "Aucun compte sélectionné à ajouter",
            "Backup not found": "Sauvegarde introuvable",
            "Failed to create restore folder": "Impossible de créer le dossier de restauration",
            "Failed to open backup": "Impossible d’ouvrir la sauvegarde",
            "Backup file is corrupted": "Le fichier de sauvegarde est corrompu",
            "Backup decryption failed": "Échec du déchiffrement de la sauvegarde",
            "The selected account is missing from the backup": "Le compte sélectionné est absent de la sauvegarde",
            "The selected account data is missing": "Les données du compte sélectionné sont absentes",
        ],
        "tr": [
            "Account data path is unavailable": "Hesap verileri yolu kullanılamıyor",
            "No account data available for backup": "Yedeklenecek hesap verisi yok",
            "Backup is too large": "Yedek çok büyük",
            "Failed to create backup file": "Yedek dosyası oluşturulamadı",
            "Data encryption failed": "Veri şifreleme başarısız",
            "Failed to save backup": "Yedek kaydedilemedi",
            "Failed to save key in Keychain": "Anahtar Anahtar Zinciri’ne kaydedilemedi",
            "Failed to save backup to Keychain": "Yedek Anahtar Zinciri’ne kaydedilemedi",
            "No account selected to add": "Eklenecek hesap seçilmedi",
            "Backup not found": "Yedek bulunamadı",
            "Failed to create restore folder": "Geri yükleme klasörü oluşturulamadı",
            "Failed to open backup": "Yedek açılamadı",
            "Backup file is corrupted": "Yedek dosyası bozuk",
            "Backup decryption failed": "Yedek şifresi çözülemedi",
            "The selected account is missing from the backup": "Seçilen hesap yedekte yok",
            "The selected account data is missing": "Seçilen hesabın verileri eksik",
        ],
    ]
}
