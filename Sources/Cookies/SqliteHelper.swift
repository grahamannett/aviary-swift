import Foundation
import CSQLite

enum SqliteHelper {
    static func snapshot(from dbPath: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-cookies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dest = tmp.appendingPathComponent("Cookies")
        do {
            var source: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                let error = databaseError(source)
                sqlite3_close(source)
                throw error
            }
            defer { sqlite3_close(source) }
            var destination: OpaquePointer?
            guard sqlite3_open_v2(dest.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                let error = databaseError(destination)
                sqlite3_close(destination)
                throw error
            }
            defer { sqlite3_close(destination) }
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
                throw databaseError(destination)
            }
            // SQLite reads committed WAL frames and restarts if another writer changes
            // the source. Bound both lock waits and repeated restarts.
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var status: Int32
            repeat {
                status = sqlite3_backup_step(backup, 256)
                if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                    Thread.sleep(forTimeInterval: 0.01)
                } else if status != SQLITE_OK {
                    break
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            let finishStatus = sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE else {
                if status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED {
                    throw NSError(domain: "sqlite", code: Int(SQLITE_BUSY), userInfo: [
                        NSLocalizedDescriptionKey: "Timed out acquiring a consistent cookie database snapshot."
                    ])
                }
                throw databaseError(destination)
            }
            guard finishStatus == SQLITE_OK else { throw databaseError(destination) }
            // A WAL source can leave its journal-mode header in the backup.
            // Materialize a standalone database before read-only consumers open it.
            var journalMode: OpaquePointer?
            guard sqlite3_prepare_v2(destination, "PRAGMA journal_mode=DELETE", -1, &journalMode, nil) == SQLITE_OK else {
                throw databaseError(destination)
            }
            defer { sqlite3_finalize(journalMode) }
            guard sqlite3_step(journalMode) == SQLITE_ROW else { throw databaseError(destination) }
            let mode = sqlite3_column_text(journalMode, 0).map { String(cString: $0) }
            guard mode?.caseInsensitiveCompare("delete") == .orderedSame else {
                throw NSError(domain: "sqlite", code: Int(SQLITE_ERROR), userInfo: [
                    NSLocalizedDescriptionKey: "Unable to materialize a standalone cookie database snapshot."
                ])
            }
            guard sqlite3_step(journalMode) == SQLITE_DONE else { throw databaseError(destination) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        return dest
    }

    static func query(_ dbPath: String, sql: String) throws -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let error = databaseError(db)
            sqlite3_close(db)
            throw error
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw databaseError(db) }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            var row: [String: Any] = [:]
            let cols = sqlite3_column_count(stmt)
            for i in 0 ..< cols {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, i) {
                        row[name] = String(cString: c)
                    }
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, i)
                    if let ptr = sqlite3_column_blob(stmt, i), bytes > 0 {
                        row[name] = Data(bytes: ptr, count: Int(bytes))
                    } else {
                        row[name] = Data()
                    }
                default:
                    break
                }
            }
            rows.append(row)
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw databaseError(db) }
        return rows
    }

    private static func databaseError(_ db: OpaquePointer?) -> NSError {
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unable to open cookie database"
        return NSError(domain: "sqlite", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
