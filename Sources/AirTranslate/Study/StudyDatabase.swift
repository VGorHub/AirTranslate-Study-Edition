import Darwin
import Foundation
import SQLite3

/// Used exclusively by the StudyBackend actor.
final class StudyDatabase {
    private enum Binding {
        case text(String), integer(Int64), blob(Data)
    }

    private let connection: OpaquePointer
    private let lock: Int32

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw Failure.lock }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw Failure.lock
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let database else {
            sqlite3_close(database)
            close(lock)
            throw Failure.sqlite(result)
        }
        self.connection = database
        self.lock = lock
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
        try migrate()
        try recoverInterruptedSessions()
    }

    deinit {
        sqlite3_close(connection)
        close(lock)
    }

    private func migrate() throws {
        let version = try withStatement("PRAGMA user_version") { statement in
            guard try step(statement) else { throw Failure.schema }
            return sqlite3_column_int(statement, 0)
        }
        switch version {
        case 0:
            try transaction {
                try exec("""
                    CREATE TABLE sessions (
                        id TEXT PRIMARY KEY,
                        started_at INTEGER NOT NULL,
                        active INTEGER NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX sessions_by_start ON sessions(started_at DESC, id DESC);
                    CREATE TABLE segments (
                        id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL REFERENCES sessions(id),
                        position INTEGER NOT NULL,
                        payload BLOB NOT NULL,
                        UNIQUE(session_id, position)
                    );
                    PRAGMA user_version=1;
                    """)
            }
        case 1: break
        default: throw Failure.schema
        }
    }

    private func recoverInterruptedSessions() throws {
        let interrupted = try values(StudySession.self, sql: "SELECT payload FROM sessions WHERE active = 1")
        guard !interrupted.isEmpty else { return }
        try transaction {
            for var session in interrupted {
                session.state = .interrupted
                try save(session)
            }
        }
    }

    func save(sessions: [StudySession], segments: [StudySegment]) throws {
        try transaction {
            for session in sessions { try save(session) }
            for segment in segments { try save(segment) }
        }
    }

    private func save(_ session: StudySession) throws {
        try write("""
            INSERT INTO sessions VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET active = excluded.active, payload = excluded.payload
            """, bindings: [
                .text(session.id.uuidString), .integer(Int64(session.startedAt.timeIntervalSince1970 * 1_000)),
                .integer(session.state.isActive ? 1 : 0), .blob(try JSONEncoder().encode(session))
            ])
    }

    private func save(_ segment: StudySegment) throws {
        try write("""
            INSERT INTO segments VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
            """, bindings: [
                .text(segment.id.uuidString), .text(segment.sessionID.uuidString),
                .integer(Int64(segment.position)), .blob(try JSONEncoder().encode(segment))
            ])
    }

    func sessions(offset: Int, limit: Int) throws -> [StudySession] {
        try values(StudySession.self,
                   sql: "SELECT payload FROM sessions ORDER BY started_at DESC, id DESC LIMIT ? OFFSET ?",
                   bindings: [.integer(Int64(limit)), .integer(Int64(offset))])
    }

    func session(id: UUID) throws -> StudySession? {
        try values(StudySession.self, sql: "SELECT payload FROM sessions WHERE id = ?",
                   bindings: [.text(id.uuidString)]).first
    }

    func segments(sessionID: UUID, after position: Int, limit: Int) throws -> [StudySegment] {
        try values(StudySegment.self, sql: """
            SELECT payload FROM segments
            WHERE session_id = ? AND position > ? ORDER BY position LIMIT ?
            """, bindings: [.text(sessionID.uuidString), .integer(Int64(position)), .integer(Int64(limit))])
    }

    private func transaction(_ action: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try action()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func write(_ sql: String, bindings: [Binding]) throws {
        try withStatement(sql, bindings: bindings) { statement in
            _ = try step(statement)
        }
    }

    private func values<Value: Decodable>(_ type: Value.Type, sql: String,
                                          bindings: [Binding] = []) throws -> [Value] {
        try withStatement(sql, bindings: bindings) { statement in
            var rows: [Value] = []
            let decoder = JSONDecoder()
            while try step(statement) {
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw Failure.schema }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                rows.append(try decoder.decode(type, from: data))
            }
            return rows
        }
    }

    private func exec(_ sql: String) throws {
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw Failure.sqlite(result) }
    }

    private func withStatement<Value>(_ sql: String, bindings: [Binding] = [],
                                      _ action: (OpaquePointer) throws -> Value) throws -> Value {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw Failure.sqlite(result) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let position = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let text):
                result = sqlite3_bind_text(statement, position, text, -1, transient)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, position, number)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob64(statement, position, $0.baseAddress, UInt64($0.count), transient)
                }
            }
            guard result == SQLITE_OK else { throw Failure.sqlite(result) }
        }
        return try action(statement)
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Failure.sqlite(result)
        }
    }

    enum Failure: Error {
        case lock, schema, sqlite(Int32)
    }
}
