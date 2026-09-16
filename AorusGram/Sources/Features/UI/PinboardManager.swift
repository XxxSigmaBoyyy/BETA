import Foundation
import SQLite3

// Cross-chat message pinboard. Stores pinned messages from any conversation
// in a local SQLite table. SwiftUI views observe PinboardStore (ObservableObject).
final class PinboardManager {
    static let shared = PinboardManager()
    private init() {
        queue.sync { self.openDB(); self.createTable() }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "aorusgram.pinboard", qos: .userInitiated)

    private let dbPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AorusGram", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pinboard.sqlite").path
    }()

    // MARK: - DB

    private func openDB() {
        sqlite3_open_v2(dbPath, &db,
                        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    }

    private func createTable() {
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS pinned (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id  INTEGER NOT NULL,
            peer_id     INTEGER NOT NULL,
            peer_name   TEXT,
            sender_name TEXT,
            text        TEXT,
            date        INTEGER NOT NULL,
            pinned_at   INTEGER NOT NULL,
            note        TEXT DEFAULT '',
            UNIQUE(message_id, peer_id)
        );
        """, nil, nil, nil)
    }

    // MARK: - CRUD

    func pin(messageId: Int32, peerId: Int64, peerName: String,
             senderName: String, text: String, date: Int32, note: String = "") {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            let sql = """
            INSERT OR REPLACE INTO pinned
            (message_id, peer_id, peer_name, sender_name, text, date, pinned_at, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt,  1, messageId)
            sqlite3_bind_int64(stmt, 2, peerId)
            aorusBindText(stmt, 3, peerName)
            aorusBindText(stmt, 4, senderName)
            aorusBindText(stmt, 5, text)
            sqlite3_bind_int(stmt,  6, date)
            sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970))
            aorusBindText(stmt, 8, note)
            sqlite3_step(stmt)
            DispatchQueue.main.async { PinboardStore.shared.reload() }
        }
    }

    func unpin(id: Int) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM pinned WHERE id=?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(id))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { PinboardStore.shared.reload() }
        }
    }

    func updateNote(id: Int, note: String) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE pinned SET note=? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK {
                aorusBindText(stmt, 1, note)
                sqlite3_bind_int(stmt,  2, Int32(id))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { PinboardStore.shared.reload() }
        }
    }

    func all() -> [PinnedMessage] {
        var results: [PinnedMessage] = []
        queue.sync { [weak self] in
            guard let db = self?.db else { return }
            let sql = """
            SELECT id, message_id, peer_id, peer_name, sender_name, text, date, pinned_at, note
            FROM pinned ORDER BY pinned_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(PinnedMessage(
                    id:          Int(sqlite3_column_int(stmt, 0)),
                    messageId:   sqlite3_column_int(stmt, 1),
                    peerId:      sqlite3_column_int64(stmt, 2),
                    peerName:    sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    senderName:  sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                    text:        sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
                    date:        sqlite3_column_int(stmt, 6),
                    pinnedAt:    sqlite3_column_int64(stmt, 7),
                    note:        sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                ))
            }
        }
        return results
    }

    func isPinned(messageId: Int32, peerId: Int64) -> Bool {
        var found = false
        queue.sync { [weak self] in
            guard let db = self?.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db,
               "SELECT 1 FROM pinned WHERE message_id=? AND peer_id=? LIMIT 1;",
               -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt,  1, messageId)
                sqlite3_bind_int64(stmt, 2, peerId)
                found = sqlite3_step(stmt) == SQLITE_ROW
                sqlite3_finalize(stmt)
            }
        }
        return found
    }
}

// MARK: - Model

struct PinnedMessage: Identifiable {
    let id: Int
    let messageId: Int32
    let peerId: Int64
    let peerName: String
    let senderName: String
    let text: String
    let date: Int32
    let pinnedAt: Int64
    var note: String

    var sentDate: Date   { Date(timeIntervalSince1970: TimeInterval(date)) }
    var pinDate: Date    { Date(timeIntervalSince1970: TimeInterval(pinnedAt)) }
}

// MARK: - Observable store for SwiftUI

import Combine

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


final class PinboardStore: ObservableObject {
    static let shared = PinboardStore()
    private init() { reload() }

    @Published private(set) var items: [PinnedMessage] = []

    func reload() {
        items = PinboardManager.shared.all()
    }
}
