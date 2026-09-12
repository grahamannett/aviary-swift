import Foundation
import SQLite3

enum SqliteHelper {
    static func copyDbWithSidecars(from dbPath: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-cookies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dest = tmp.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(atPath: dbPath, toPath: dest.path)
        for suffix in ["-wal", "-shm"] {
            let side = dbPath + suffix
            if FileManager.default.fileExists(atPath: side) {
                try? FileManager.default.copyItem(atPath: side, toPath: dest.path + suffix)
            }
        }
        return dest
    }

    static func query(_ dbPath: String, sql: String) -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
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
        }
        return rows
    }
}
