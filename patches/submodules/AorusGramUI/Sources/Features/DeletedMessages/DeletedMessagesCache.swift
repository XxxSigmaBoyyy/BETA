import Foundation
import SQLite3
import BackgroundTasks

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

    private func createTable() {
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
            PRIMARY KEY (id, peer_id)
        );
        CREATE INDEX IF NOT EXISTS idx_peer_date ON messages(peer_id, date DESC);
        CREATE INDEX IF NOT EXISTS idx_status    ON messages(peer_id, status, edited_at, date DESC);
        """, nil, nil, nil)

        // Idempotent migration for users upgrading from earlier schema (no-op
        // if column already exists — sqlite returns SQLITE_ERROR which we ignore).
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN original_text TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN edited_at INTEGER;", nil, nil, nil)
    }

    // MARK: - Cache API (called from two hooks)

    /// Cache a message that just arrived. Call before any deletion.
    func cacheMessage(
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
            (id, peer_id, sender_id, sender_name, text, date, cached_at, deleted_at, media_type, media_path, is_outgoing, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt,  1, id)
            sqlite3_bind_int64(stmt, 2, peerId)
            sqlite3_bind_int64(stmt, 3, senderId ?? 0)
            sqlite3_bind_text(stmt, 4, senderName ?? "", -1, nil)
            sqlite3_bind_text(stmt, 5, text ?? "", -1, nil)
            sqlite3_bind_int(stmt,  6, date)
            sqlite3_bind_int64(stmt, 7, now)
            if markDeleted {
                sqlite3_bind_int64(stmt, 8, now)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_text(stmt, 9,  mediaType ?? "", -1, nil)
            sqlite3_bind_text(stmt, 10, mediaPath ?? "", -1, nil)
            sqlite3_bind_int(stmt,  11, isOutgoing ? 1 : 0)
            sqlite3_bind_int(stmt,  12, markDeleted ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    /// Mark an already-cached message as deleted (called when server sends delete update).
    func markDeleted(id: Int32, peerId: Int64) {
        guard AorusGramConfig.isEnabled(.deletedMessages) else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE messages SET status=1, deleted_at=? WHERE id=? AND peer_id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt,  2, id)
            sqlite3_bind_int64(stmt, 3, peerId)
            sqlite3_step(stmt)
        }
    }

    /// Record that a message was edited. Stores `original_text` only on the FIRST
    /// edit (subsequent edits update `text` but keep the first-known original) so
    /// the user always sees the very first version, not the most-recent-but-one.
    /// Inserts a stub row if the message was never pre-cached.
    func markEdited(id: Int32, peerId: Int64, originalText: String, newText: String, date: Int32) {
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
            WHERE id = ? AND peer_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, newText,      -1, nil)
            sqlite3_bind_text(stmt, 2, originalText, -1, nil)
            sqlite3_bind_int64(stmt, 3, now)
            sqlite3_bind_int(stmt,   4, id)
            sqlite3_bind_int64(stmt, 5, peerId)
            sqlite3_step(stmt)
            let changed = sqlite3_changes(db)
            sqlite3_finalize(stmt)
            if changed > 0 { return }

            // 2. No pre-cached row — insert a stub so the edit is still visible.
            let insertSQL = """
            INSERT OR REPLACE INTO messages
            (id, peer_id, sender_id, sender_name, text, original_text, edited_at,
             date, cached_at, deleted_at, media_type, media_path, is_outgoing, status)
            VALUES (?, ?, 0, '', ?, ?, ?, ?, ?, NULL, '', '', 0, 0);
            """
            var ins: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &ins, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(ins) }
            sqlite3_bind_int(ins,  1, id)
            sqlite3_bind_int64(ins, 2, peerId)
            sqlite3_bind_text(ins, 3, newText,      -1, nil)
            sqlite3_bind_text(ins, 4, originalText, -1, nil)
            sqlite3_bind_int64(ins, 5, now)
            sqlite3_bind_int(ins,  6, date)
            sqlite3_bind_int64(ins, 7, now)
            sqlite3_step(ins)
        }
    }

    // MARK: - Fetch

    /// Returns rows that are either deleted (status=1) OR edited (original_text NOT NULL).
    /// The UI surfaces both — for edits we show current text + 'Оригинал:' line.
    func deletedMessages(peerId: Int64, limit: Int = 200) -> [DeletedMessage] {
        var results: [DeletedMessage] = []
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            // peerId=0 means "all chats"
            let allChats = peerId == 0
            let sql = allChats ? """
                SELECT id, peer_id, sender_id, sender_name, text, original_text, edited_at,
                       date, deleted_at, media_type, media_path, is_outgoing, status
                FROM messages
                WHERE status=1 OR original_text IS NOT NULL
                ORDER BY COALESCE(edited_at, deleted_at, date) DESC LIMIT ?;
            """ : """
                SELECT id, peer_id, sender_id, sender_name, text, original_text, edited_at,
                       date, deleted_at, media_type, media_path, is_outgoing, status
                FROM messages
                WHERE peer_id=? AND (status=1 OR original_text IS NOT NULL)
                ORDER BY COALESCE(edited_at, deleted_at, date) DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if allChats {
                sqlite3_bind_int(stmt, 1, Int32(limit))
            } else {
                sqlite3_bind_int64(stmt, 1, peerId)
                sqlite3_bind_int(stmt,   2, Int32(limit))
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
    func allDeletedCount() -> Int {
        var count = 0
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM messages WHERE status=1 OR original_text IS NOT NULL;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
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
              let msgId  = (info["msgId"]  as? NSNumber)?.int32Value,
              let peerId = (info["peerId"] as? NSNumber)?.int64Value
        else { return }
        let senderId   = (info["senderId"] as? NSNumber)?.int64Value
        let senderName = info["senderName"] as? String
        let text       = info["text"]       as? String
        let date       = (info["date"]      as? NSNumber)?.int32Value ?? 0

        cacheMessage(
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
              let msgId = (info["msgId"] as? NSNumber)?.int32Value
        else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE messages SET status=1, deleted_at=? WHERE id=? AND status=0;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt,  2, msgId)
            sqlite3_step(stmt)
        }
    }

    /// Handle the NotificationCenter event posted by the TelegramCore delete patch.
    /// The hook now only sends msgId + peerId (no text/author — those APIs don't
    /// compile on `any Peer` in Postbox). Text is preserved from the pre-cached row.
    func handleWillDeleteNotification(_ note: Notification) {
        guard AorusGramConfig.isEnabled(.deletedMessages),
              let info   = note.userInfo,
              let msgId  = (info[AorusDMCNotifKey.msgId]  as? NSNumber)?.int32Value,
              let peerId = (info[AorusDMCNotifKey.peerId] as? NSNumber)?.int64Value
        else { return }
        markDeleted(id: msgId, peerId: peerId)
    }

    /// Handle the NotificationCenter event posted by the TelegramCore edit patch.
    /// The patch reads `prev.text` via `transaction.getMessage(id)` BEFORE applying
    /// the update, so we always get the actual pre-edit content.
    func handleWillEditNotification(_ note: Notification) {
        guard AorusGramConfig.isEnabled(.deletedMessages),
              let info     = note.userInfo,
              let msgId    = (info["msgId"]        as? NSNumber)?.int32Value,
              let peerId   = (info["peerId"]       as? NSNumber)?.int64Value,
              let original = info["originalText"]  as? String,
              let newText  = info["newText"]       as? String
        else { return }
        let date = (info["date"] as? NSNumber)?.int32Value ?? 0
        markEdited(id: msgId, peerId: peerId, originalText: original, newText: newText, date: date)
    }
}
