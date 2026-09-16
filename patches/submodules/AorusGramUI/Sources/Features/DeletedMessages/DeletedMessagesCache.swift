import Foundation
import SQLite3
import BackgroundTasks

/// Binds a Swift string to a statement parameter so SQLite owns the bytes.
///
/// `sqlite3_bind_text` with a `nil` destructor means SQLITE_STATIC: "this pointer stays
/// valid, do not copy it". A Swift `String` handed to a C `const char *` parameter is a
/// TEMPORARY buffer that is gone the moment the call returns, and SQLite reads the value
/// later — at `sqlite3_step`. Every text column written that way read back whatever was in
/// that memory by then, which in practice was the last string bound, repeated across all
/// of them.
///
/// The length is the real byte count rather than -1, so a string containing a NUL is
/// stored whole instead of being cut at it.
private func aorusBindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
    // SQLITE_TRANSIENT is (sqlite3_destructor_type)-1 and has no Swift symbol of its own.
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let bytes = Array(value.utf8)
    if bytes.isEmpty {
        sqlite3_bind_text(statement, index, "", 0, transient)
        return
    }
    bytes.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
            sqlite3_bind_text(statement, index, pointer, Int32(buffer.count), transient)
        }
    }
}


// Persists all incoming messages so content survives deletion.
//
// Architecture:
//   1. Messages are cached TWO ways:
//      a) Via TelegramCore callback (aorusDeleteInterceptor) — fires right before
//         postbox.deleteMessages(), giving us the full text even for offline deletes.
//      b) Via cacheFromChatItem() — called from the patched ChatMessageItem as messages
//         are rendered, covering any gap the interceptor misses (e.g., historic messages
//         seen in the chat before the feature was enabled).
//   2. BGAppRefreshTask runs every ~15 min to flush a pending queue and mark
//      messages confirmed-deleted when the interceptor fired.
//   3. deletedMessages(peerId:) returns only entries that were confirmed deleted
//      (status = 1), so the user only sees actually-gone content.
final class DeletedMessagesCache {
    static let shared = DeletedMessagesCache()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "aorusgram.dmc", qos: .background)
    private let dbPath: String

    // Background task identifier registered in Info.plist and AppDelegate
    static let bgTaskID = "com.aorusgram.dmc.sync"

    // MARK: - Init / DB setup

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AorusGram", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("deleted_messages.sqlite").path
        queue.sync { self.openDB(); self.createTable() }
    }

    private func openDB() {
        if sqlite3_open_v2(dbPath, &db,
                           SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            db = nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
    }

    /// A stable per-account number derived from that account's own storage path.
    ///
    /// Every row belongs to ONE account. Before this there was no such column: the table
    /// was keyed by `(id, peer_id)` alone, one file was shared by every account signed in,
    /// and a message id is only unique WITHIN an account. Two accounts that both talk to
    /// the same person — or are both in the same channel — overwrote each other's rows, so
    /// a deleted message from a work account could be read in a personal one and a delete
    /// in one marked the other's row as gone.
    ///
    /// The key is the account's media storage path, hashed. That path is what every
    /// interception site has in hand (`mediaBox.basePath`), it is distinct per account and
    /// stable for as long as the account exists on the device — and it changes exactly when
    /// the account is removed and added again, which is when a fresh key is wanted.
    ///
    /// FNV-1a rather than `hashValue`: Swift seeds its hasher per process, so the same path
    /// would key different rows on the next launch.
    static func accountKey(forStoragePath path: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // Folded into the non-negative range so the column never carries a sign no reader
        // expects, and never zero, which is reserved for "unattributed".
        let folded = Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
        return folded == 0 ? 1 : folded
    }

    private func createTable() {
        // Rows written before the account column existed cannot be attributed to anyone.
        // Keeping them would mean showing one account's history inside another's, which is
        // the whole defect; they are dropped once, and the cache refills from live traffic.
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS messages (
            id            INTEGER,
            peer_id       INTEGER NOT NULL,
            sender_id     INTEGER,
            sender_name   TEXT,
            text          TEXT,
            original_text TEXT,                  -- pre-edit text (NULL if never edited)
            edited_at     INTEGER,               -- unix ts of last edit, NULL if never edited
            date          INTEGER NOT NULL,
            cached_at     INTEGER NOT NULL,
            deleted_at    INTEGER,
            media_type    TEXT,
            media_path    TEXT,
            is_outgoing   INTEGER DEFAULT 0,
            status        INTEGER DEFAULT 0,     -- 0=cached, 1=deleted
            account_key   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (account_key, peer_id, id)
        );
        CREATE INDEX IF NOT EXISTS idx_peer_date ON messages(account_key, peer_id, date DESC);
        CREATE INDEX IF NOT EXISTS idx_status    ON messages(account_key, peer_id, status, edited_at, date DESC);
        """, nil, nil, nil)
        migrateToAccountScopedSchema()

        // Idempotent migration for users upgrading from earlier schema (no-op
        // if column already exists — sqlite returns SQLITE_ERROR which we ignore).
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN original_text TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN edited_at INTEGER;", nil, nil, nil)
    }

    /// Bring a table written by an earlier build up to the account-scoped schema.
    ///
    /// SQLite cannot change a primary key in place, so the table is rebuilt. Nothing is
    /// carried over: every existing row predates the account column and there is no way to
    /// say whose it was. Attributing them to whoever happens to be signed in would be the
    /// same leak under a new name.
    private func migrateToAccountScopedSchema() {
        guard let db else { return }
        var stmt: OpaquePointer?
        var hasAccountKey = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(messages);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                   name == "account_key" {
                    hasAccountKey = true
                }
            }
        }
        sqlite3_finalize(stmt)
        guard !hasAccountKey else { return }
        sqlite3_exec(db, """
        BEGIN IMMEDIATE;
        DROP TABLE IF EXISTS messages;
        CREATE TABLE messages (
            id            INTEGER,
            peer_id       INTEGER NOT NULL,
            sender_id     INTEGER,
            sender_name   TEXT,
            text          TEXT,
            original_text TEXT,
            edited_at     INTEGER,
            date          INTEGER NOT NULL,
            cached_at     INTEGER NOT NULL,
            deleted_at    INTEGER,
            media_type    TEXT,
            media_path    TEXT,
            is_outgoing   INTEGER DEFAULT 0,
            status        INTEGER DEFAULT 0,
            account_key   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (account_key, peer_id, id)
        );
        CREATE INDEX idx_peer_date ON messages(account_key, peer_id, date DESC);
        CREATE INDEX idx_status    ON messages(account_key, peer_id, status, edited_at, date DESC);
        COMMIT;
        """, nil, nil, nil)
    }

    // MARK: - Cache API (called from two hooks)

    /// Cache a message that just arrived. Call before any deletion.
    func cacheMessage(
        accountKey: Int64,
        id: Int32,
        peerId: Int64,
        senderId: Int64?,
        senderName: String?,
        text: String?,
        date: Int32,
        mediaType: String? = nil,
        mediaPath: String? = nil,
        isOutgoing: Bool,
        markDeleted: Bool = false
    ) {
        guard AorusGramConfig.isEnabled(.deletedMessages) else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
            INSERT OR REPLACE INTO messages
            (id, peer_id, sender_id, sender_name, text, date, cached_at, deleted_at, media_type, media_path, is_outgoing, status, account_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt,  1, id)
            sqlite3_bind_int64(stmt, 2, peerId)
            sqlite3_bind_int64(stmt, 3, senderId ?? 0)
            aorusBindText(stmt, 4, senderName ?? "")
            aorusBindText(stmt, 5, text ?? "")
            sqlite3_bind_int(stmt,  6, date)
            sqlite3_bind_int64(stmt, 7, now)
            if markDeleted {
                sqlite3_bind_int64(stmt, 8, now)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            aorusBindText(stmt, 9, mediaType ?? "")
            aorusBindText(stmt, 10, mediaPath ?? "")
            sqlite3_bind_int(stmt,  11, isOutgoing ? 1 : 0)
            sqlite3_bind_int(stmt,  12, markDeleted ? 1 : 0)
            sqlite3_bind_int64(stmt, 13, accountKey)
            sqlite3_step(stmt)
        }
    }

    /// Mark an already-cached message as deleted (called when server sends delete update).
    func markDeleted(accountKey: Int64, id: Int32, peerId: Int64) {
        guard AorusGramConfig.isEnabled(.deletedMessages) else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE messages SET status=1, deleted_at=? WHERE account_key=? AND id=? AND peer_id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, accountKey)
            sqlite3_bind_int(stmt,  3, id)
            sqlite3_bind_int64(stmt, 4, peerId)
            sqlite3_step(stmt)
        }
    }

    /// Record that a message was edited. Stores `original_text` only on the FIRST
    /// edit (subsequent edits update `text` but keep the first-known original) so
    /// the user always sees the very first version, not the most-recent-but-one.
    /// Inserts a stub row if the message was never pre-cached.
    func markEdited(accountKey: Int64, id: Int32, peerId: Int64, originalText: String, newText: String, date: Int32) {
        guard AorusGramConfig.isEnabled(.deletedMessages) else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let now = Int64(Date().timeIntervalSince1970)

            // 1. Preserve original_text only if not already set; always refresh `text`.
            let updateSQL = """
            UPDATE messages
            SET text = ?,
                original_text = COALESCE(original_text, ?),
                edited_at = ?
            WHERE account_key = ? AND id = ? AND peer_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else { return }
            aorusBindText(stmt, 1, newText)
            aorusBindText(stmt, 2, originalText)
            sqlite3_bind_int64(stmt, 3, now)
            sqlite3_bind_int64(stmt, 4, accountKey)
            sqlite3_bind_int(stmt,   5, id)
            sqlite3_bind_int64(stmt, 6, peerId)
            sqlite3_step(stmt)
            let changed = sqlite3_changes(db)
            sqlite3_finalize(stmt)
            if changed > 0 { return }

            // 2. No pre-cached row — insert a stub so the edit is still visible.
            let insertSQL = """
            INSERT OR REPLACE INTO messages
            (id, peer_id, sender_id, sender_name, text, original_text, edited_at,
             date, cached_at, deleted_at, media_type, media_path, is_outgoing, status, account_key)
            VALUES (?, ?, 0, '', ?, ?, ?, ?, ?, NULL, '', '', 0, 0, ?);
            """
            var ins: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &ins, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(ins) }
            sqlite3_bind_int(ins,  1, id)
            sqlite3_bind_int64(ins, 2, peerId)
            aorusBindText(ins, 3, newText)
            aorusBindText(ins, 4, originalText)
            sqlite3_bind_int64(ins, 5, now)
            sqlite3_bind_int(ins,  6, date)
            sqlite3_bind_int64(ins, 7, now)
            sqlite3_bind_int64(ins, 8, accountKey)
            sqlite3_step(ins)
        }
    }

    // MARK: - Fetch

    /// Returns rows that are either deleted (status=1) OR edited (original_text NOT NULL).
    /// The UI surfaces both — for edits we show current text + 'Оригинал:' line.
    func deletedMessages(accountKey: Int64, peerId: Int64, limit: Int = 200) -> [DeletedMessage] {
        var results: [DeletedMessage] = []
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            // peerId=0 means "all chats"
            let allChats = peerId == 0
            let sql = allChats ? """
                SELECT id, peer_id, sender_id, sender_name, text, original_text, edited_at,
                       date, deleted_at, media_type, media_path, is_outgoing, status
                FROM messages
                WHERE account_key=? AND (status=1 OR original_text IS NOT NULL)
                ORDER BY COALESCE(edited_at, deleted_at, date) DESC LIMIT ?;
            """ : """
                SELECT id, peer_id, sender_id, sender_name, text, original_text, edited_at,
                       date, deleted_at, media_type, media_path, is_outgoing, status
                FROM messages
                WHERE account_key=? AND peer_id=? AND (status=1 OR original_text IS NOT NULL)
                ORDER BY COALESCE(edited_at, deleted_at, date) DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, accountKey)
            if allChats {
                sqlite3_bind_int(stmt, 2, Int32(limit))
            } else {
                sqlite3_bind_int64(stmt, 2, peerId)
                sqlite3_bind_int(stmt,   3, Int32(limit))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idVal     = sqlite3_column_int(stmt, 0)
                let peerVal   = sqlite3_column_int64(stmt, 1)
                let sender    = sqlite3_column_int64(stmt, 2)
                let sName     = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let txt       = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let origText  = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let editedAt  = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6)
                let date      = sqlite3_column_int(stmt, 7)
                let delAt     = sqlite3_column_int64(stmt, 8)
                let mType     = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
                let mPath     = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""
                let isOut     = sqlite3_column_int(stmt, 11) != 0
                let status    = sqlite3_column_int(stmt, 12)
                results.append(DeletedMessage(
                    id: idVal, peerId: peerVal,
                    senderId: sender, senderName: sName,
                    text: txt, originalText: origText, editedAt: editedAt,
                    date: date, deletedAt: delAt,
                    mediaType: mType, mediaPath: mPath,
                    isOutgoing: isOut,
                    isDeleted: status == 1
                ))
            }
        }
        return results
    }

    /// Total number of items shown in the "Deleted" view: deletions + edits.
    func allDeletedCount(accountKey: Int64) -> Int {
        var count = 0
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM messages WHERE account_key=? AND (status=1 OR original_text IS NOT NULL);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, accountKey)
                if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
        }
        return count
    }

    /// Wipe ALL stored messages (deleted + edited + plain pre-cached).
    /// Called from the "Очистить кеш" button in Settings.
    func clearAll() {
        queue.async { [weak self] in
            sqlite3_exec(self?.db, "DELETE FROM messages;", nil, nil, nil)
            // VACUUM reclaims the freed pages so the file shrinks.
            sqlite3_exec(self?.db, "VACUUM;", nil, nil, nil)
        }
    }

    // MARK: - BGTask

    func registerBackgroundTask() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskID, using: nil) { [weak self] task in
                // Conditional, not forced. Only a BGAppRefreshTaskRequest is ever submitted
                // for this identifier, so the cast holds today — but a forced one turns a
                // future change of task type into a crash in the background, where nobody
                // sees it and the system withdraws the app's refresh budget for it. An
                // unexpected task is completed instead, which is what the scheduler needs.
                guard let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.handleBGTask(refresh)
            }
        }
    }

    func scheduleBackgroundSync() {
        if #available(iOS 13.0, *) {
            let req = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
            req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(req)
        }
    }

    private func handleBGTask(_ task: BGAppRefreshTask) {
        scheduleBackgroundSync()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        // Flush any pending ops and compact the WAL
        queue.async { [weak self] in
            sqlite3_exec(self?.db, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
            task.setTaskCompleted(success: true)
        }
    }
}

// MARK: - Model

struct DeletedMessage: Identifiable {
    let id: Int32
    let peerId: Int64
    let senderId: Int64
    let senderName: String
    let text: String              // current (or final-before-delete) text
    let originalText: String?     // pre-edit text — only set when isEdited
    let editedAt: Int64?
    let date: Int32
    let deletedAt: Int64
    let mediaType: String
    let mediaPath: String
    let isOutgoing: Bool
    let isDeleted: Bool

    var isEdited: Bool    { originalText != nil && originalText != text }
    var sentDate: Date    { Date(timeIntervalSince1970: TimeInterval(date)) }
    var deletedDate: Date { Date(timeIntervalSince1970: TimeInterval(deletedAt)) }
    var editedDate: Date? { editedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var hasMedia: Bool    { !mediaType.isEmpty }
}

// MARK: - TelegramCore intercept bridge (NotificationCenter)
//
// TelegramCore и main app — разные Swift-модули (TelegramCore — framework).
// Прямой вызов функции из одного модуля в другой невозможен без circular dependency.
// Решение: NotificationCenter работает across module boundaries через Foundation.
//
// aorus_branding.py патчит AccountStateManager.swift и добавляет перед
// transaction.deleteMessages(...):
//   NotificationCenter.default.post(name: NSNotification.Name("aorusgram.willDeleteMessage"), ...)
//
// AorusGramBootstrap.setup() подписывается на это уведомление и вызывает
// DeletedMessagesCache.shared.cacheMessage(...).

extension Notification.Name {
    static let aorusWillDeleteMessage         = Notification.Name("aorusgram.willDeleteMessage")
    static let aorusWillDeleteMessageGlobalId = Notification.Name("aorusgram.willDeleteMessageGlobalId")
    static let aorusWillEditMessage           = Notification.Name("aorusgram.willEditMessage")
}

// UserInfo keys for .aorusWillDeleteMessage notification
enum AorusDMCNotifKey {
    static let msgId      = "msgId"      // NSNumber Int32
    static let peerId     = "peerId"     // NSNumber Int64
    static let senderId   = "senderId"   // NSNumber Int64
    static let senderName = "senderName" // String
    static let text       = "text"       // String
    static let date       = "date"       // NSNumber Int32
    static let isOutgoing = "isOutgoing" // NSNumber Bool
    /// The media storage path of the account the event belongs to. Every interception
    /// site has it in hand, and it is what keeps one account's rows out of another's.
    static let accountPath = "accountPath" // String
}

extension DeletedMessagesCache {
    /// The account an event came from, or nil when the event carries no origin.
    ///
    /// An event with no account is not written anywhere. A row that cannot be attributed
    /// is a row that will be read by whoever is signed in, which is the defect itself —
    /// and an event from a build whose hook was not updated is better dropped than filed
    /// under the wrong person.
    static func accountKey(from info: [AnyHashable: Any]?) -> Int64? {
        guard let path = info?[AorusDMCNotifKey.accountPath] as? String, !path.isEmpty else {
            return nil
        }
        return accountKey(forStoragePath: path)
    }
}

extension DeletedMessagesCache {
    /// Pre-cache an incoming message before any potential deletion.
    /// Called from AorusGramBootstrap when it receives `aorusgram.didReceiveMessage`.
    /// Without this, we'd lose the text whenever transaction.getMessage(id) returns nil
    /// at delete-time (which happens often — Telegram may purge the postbox entry before
    /// our delete-hook reaches it).
    func handleIncomingNotification(_ note: Notification) {
        guard AorusGramConfig.isEnabled(.deletedMessages),
              let info   = note.userInfo,
              let accountKey = Self.accountKey(from: info),
              let msgId  = (info["msgId"]  as? NSNumber)?.int32Value,
              let peerId = (info["peerId"] as? NSNumber)?.int64Value
        else { return }
        let senderId   = (info["senderId"] as? NSNumber)?.int64Value
        let senderName = info["senderName"] as? String
        let text       = info["text"]       as? String
        let date       = (info["date"]      as? NSNumber)?.int32Value ?? 0

        cacheMessage(
            accountKey: accountKey,
            id: msgId, peerId: peerId,
            senderId: senderId, senderName: senderName,
            text: text, date: date,
            isOutgoing: false, markDeleted: false
        )
    }

    /// Global-id delete (non-channel chats). Server sends bare Int32 IDs without peer
    /// context. We flip status=1 on any pre-cached row matching that global id.
    /// Without a peer match we can't reliably insert a stub, so we just update existing.
    func handleWillDeleteByGlobalIdNotification(_ note: Notification) {
        guard AorusGramConfig.isEnabled(.deletedMessages),
              let info  = note.userInfo,
              let accountKey = Self.accountKey(from: info),
              let msgId = (info["msgId"] as? NSNumber)?.int32Value
        else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            // Scoped to the account the event came from. Without that clause this marked
            // every account's row carrying the same number as deleted, and a message id is
            // only unique within one account.
            let sql = "UPDATE messages SET status=1, deleted_at=? WHERE account_key=? AND id=? AND status=0;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, accountKey)
            sqlite3_bind_int(stmt,  3, msgId)
            sqlite3_step(stmt)
        }
    }

    /// Handle the NotificationCenter event posted by the TelegramCore delete patch.
    /// The hook now only sends msgId + peerId (no text/author — those APIs don't
    /// compile on `any Peer` in Postbox). Text is preserved from the pre-cached row.
    func handleWillDeleteNotification(_ note: Notification) {
        guard AorusGramConfig.isEnabled(.deletedMessages),
              let info   = note.userInfo,
              let accountKey = Self.accountKey(from: info),
              let msgId  = (info[AorusDMCNotifKey.msgId]  as? NSNumber)?.int32Value,
              let peerId = (info[AorusDMCNotifKey.peerId] as? NSNumber)?.int64Value
        else { return }
        markDeleted(accountKey: accountKey, id: msgId, peerId: peerId)
    }

    /// Handle the NotificationCenter event posted by the TelegramCore edit patch.
    /// The patch reads `prev.text` via `transaction.getMessage(id)` BEFORE applying
    /// the update, so we always get the actual pre-edit content.
    func handleWillEditNotification(_ note: Notification) {
        guard AorusGramConfig.isEnabled(.deletedMessages),
              let info     = note.userInfo,
              let accountKey = Self.accountKey(from: info),
              let msgId    = (info["msgId"]        as? NSNumber)?.int32Value,
              let peerId   = (info["peerId"]       as? NSNumber)?.int64Value,
              let original = info["originalText"]  as? String,
              let newText  = info["newText"]       as? String
        else { return }
        let date = (info["date"] as? NSNumber)?.int32Value ?? 0
        markEdited(accountKey: accountKey, id: msgId, peerId: peerId,
                   originalText: original, newText: newText, date: date)
    }
}
