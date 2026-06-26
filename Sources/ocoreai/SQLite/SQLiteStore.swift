// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SQLiteStore.swift — WAL-mode SQLite connection management and schema initialization
///
/// Actor-isolated for strict concurrency safety. Handles schema migration, WAL configuration,
/// and provides a safe connection pool for session/message storage.

import Darwin
import Foundation

// MARK: - SQLite3 C Bindings

// SQLite result codes
private let SQLITE_OK: CInt = 0
private let SQLITE_ROW: CInt = 100
private let SQLITE_DONE: CInt = 101

// SQLite value types
private let SQLITE_INTEGER: CInt = 1
private let SQLITE_FLOAT: CInt = 2
private let SQLITE_TEXT: CInt = 3
private let SQLITE_BLOB: CInt = 4
private let SQLITE_NULL: CInt = 5

// Open flags
private let SQLITE_OPEN_READWRITE: CInt = 0x0002
private let SQLITE_OPEN_CREATE: CInt = 0x0004
private let SQLITE_OPEN_FULLMUTEX: CInt = 0x00010

// ─── C function imports via @_silgen_name ───

@_silgen_name("sqlite3_open_v2")
private func _open_v2(
	_ filename: UnsafePointer<Int8>?,
	_ ppDb: UnsafeMutablePointer<OpaquePointer?>?,
	_ flags: CInt,
	_ zVfs: UnsafePointer<Int8>?,
) -> CInt

@_silgen_name("sqlite3_close")
private func _close(_ db: OpaquePointer) -> CInt

@_silgen_name("sqlite3_prepare_v2")
private func _prepare_v2(
	_ db: OpaquePointer,
	_ sql: UnsafePointer<Int8>,
	_ len: CInt,
	_ ppStmt: UnsafeMutablePointer<OpaquePointer?>?,
	_ pzTail: UnsafeMutablePointer<UnsafePointer<Int8>?>?,
) -> CInt

@_silgen_name("sqlite3_step")
private func _step(_ stmt: OpaquePointer) -> CInt

@_silgen_name("sqlite3_finalize")
private func _finalize(_ stmt: OpaquePointer?) -> CInt

@_silgen_name("sqlite3_bind_int64")
private func _bind_int64(_ stmt: OpaquePointer, _ index: CInt, _ value: Int64) -> CInt

@_silgen_name("sqlite3_bind_double")
private func _bind_double(_ stmt: OpaquePointer, _ index: CInt, _ value: Double) -> CInt

@_silgen_name("sqlite3_bind_text")
private func _bind_text(
	_ stmt: OpaquePointer,
	_ index: CInt,
	_ text: UnsafePointer<Int8>,
	_ len: CInt,
	_ pDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void,
) -> CInt

@_silgen_name("sqlite3_bind_blob")
private func _bind_blob(
	_ stmt: OpaquePointer,
	_ index: CInt,
	_ blob: UnsafeRawPointer?,
	_ len: CInt,
	_ pDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void,
) -> CInt

@_silgen_name("sqlite3_column_count")
private func _column_count(_ stmt: OpaquePointer) -> CInt

@_silgen_name("sqlite3_column_type")
private func _column_type(_ stmt: OpaquePointer, _ index: CInt) -> CInt

@_silgen_name("sqlite3_column_int64")
private func _column_int64(_ stmt: OpaquePointer, _ index: CInt) -> Int64

@_silgen_name("sqlite3_column_double")
private func _column_double(_ stmt: OpaquePointer, _ index: CInt) -> Double

@_silgen_name("sqlite3_column_text")
private func _column_text(_ stmt: OpaquePointer, _ index: CInt) -> UnsafePointer<Int8>?

@_silgen_name("sqlite3_column_blob")
private func _column_blob(_ stmt: OpaquePointer, _ index: CInt) -> UnsafeRawPointer?

@_silgen_name("sqlite3_column_bytes")
private func _column_bytes(_ stmt: OpaquePointer, _ index: CInt) -> CInt

@_silgen_name("sqlite3_column_name")
private func _column_name(_ stmt: OpaquePointer, _ index: CInt) -> UnsafePointer<Int8>?

@_silgen_name("sqlite3_errmsg")
private func _errmsg(_ db: OpaquePointer) -> UnsafePointer<Int8>?

// Destroy callback for sqlite3_bind_* — tells SQLite to copy data
private let SQLITE_TRANSIENT: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in }

// MARK: - Connection Wrapper

/// Wrapper around C sqlite3 opaque pointer. Sendable because connection is actor-isolated.
final class SQLiteConnection: @unchecked Sendable {
	let pointer: OpaquePointer

	init(_ pointer: OpaquePointer) {
		self.pointer = pointer
	}

	deinit {
		_ = _close(pointer)
	}
}

// MARK: - SQLiteStore Actor

/// Actor managing the SQLite database connection and lifecycle.
actor SQLiteStore {
	private let dbPath: String
	private var connection: SQLiteConnection?

	/// Path description for logging
	nonisolated var dbPathDescription: String {
		dbPath
	}

	/// Default database path — cross-platform (macOS/iOS/iPadOS).
	/// macOS: ~/Library/Application Support/ocoreai/data/ocoreai.sqlite
	/// iOS/iPadOS: sandbox/Library/Application Support/ocoreai/data/ocoreai.sqlite
	static let defaultPath: String = {
		guard let supportURL = FileManager.default.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
		).first?.appendingPathComponent("ocoreai/data") else {
			fatalError("[SQLiteStore] applicationSupportDirectory not available")
		}
		let dataDir = supportURL.path
		try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
		return (dataDir as NSString).appendingPathComponent("ocoreai.sqlite")
	}()

	/// Create store at the given path (defaults to ~/.ocoreai/data/ocoreai.sqlite).
	init(path: String = SQLiteStore.defaultPath) {
		dbPath = path
	}

	/// Open the database connection and ensure schema is current.
	func open() throws {
		guard connection == nil else { return }

		var dbPtr: OpaquePointer?
		let result = (dbPath as NSString).utf8String.map { _open_v2($0, &dbPtr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) } ?? SQLITE_OK

		guard result == SQLITE_OK, let ptr = dbPtr else {
			throw SQLiteError.connectionFailed(detail: "sqlite3_open error: \(result)")
		}

		// PRAGMAs
		try SQLiteStore.exec(sql: "PRAGMA journal_mode=WAL;", db: ptr)
		try SQLiteStore.exec(sql: "PRAGMA foreign_keys=ON;", db: ptr)
		try SQLiteStore.exec(sql: "PRAGMA wal_checkpoint(TRUNCATE);", db: ptr)
		try SQLiteStore.exec(sql: "PRAGMA busy_timeout=5000;", db: ptr)
		try SQLiteStore.exec(sql: "PRAGMA page_size=4096;", db: ptr)

		connection = SQLiteConnection(ptr)
		try ensureSchema(db: ptr)
	}

	/// Close the database connection.
	func close() {
		connection = nil
	}

	/// Execute a SQL statement (DML/DDL).
	func execute(sql: String, parameters: [AnyHashable]? = nil) async throws {
		guard let conn = connection else { throw SQLiteError.notConnected }
		try Self.exec(sql: sql, parameters: parameters, db: conn.pointer)
	}

	/// Execute a parameterized query returning a single SQLite-safe value (Sendable across actors).
	func scalarQuery(sql: String, parameters: [AnyHashable]? = nil) async throws -> SendableValue? {
		guard let conn = connection else { throw SQLiteError.notConnected }
		let raw = try Self.scalarQ(sql: sql, parameters: parameters, db: conn.pointer)
		return Self.wrap(raw)
	}

	/// Execute a parameterized query returning multiple rows (Sendable across actors).
	func query(_ sql: String, parameters: [AnyHashable]? = nil) async throws -> [[String: SendableValue]] {
		guard let conn = connection else { throw SQLiteError.notConnected }
		let raw = try Self.query(sql: sql, parameters: parameters, db: conn.pointer)
		return Self.wrapRows(raw)
	}

	// MARK: - Helpers

	/// Wrap raw column values in a Sendable container for cross-actor safety.
	@inline(__always)
	private static func wrap(_ value: Any?) -> SendableValue? {
		guard let v = value else { return nil }
		switch v {
		case let x as Int64: return .integer(x)
		case let x as Int: return .integer(Int64(x))
		case let x as UInt64: return .integer(Int64(truncatingIfNeeded: x))
		case let x as Double: return .float(x)
		case let x as Float: return .float(Double(x))
		case let x as String: return .text(x)
		case let x as Data: return .blob(x)
		case is NSNull: return .null
		default: return .null
		}
	}

	/// Wrap rows: [[String: Any]] -> [[String: SendableValue]] for safe cross-actor return.
	private static func wrapRows(_ rows: [[String: Any]]) -> [[String: SendableValue]] {
		rows.map { row in
			row.mapValues { Self.wrap($0) ?? .null }
		}
	}

	/// Check if sqlite3 result code indicates an error
	private static func isErr(_ code: CInt) -> Bool {
		code != SQLITE_OK && code != SQLITE_ROW && code != SQLITE_DONE
	}

	/// Get error message string from database handle
	private static func errMsg(_ db: OpaquePointer) -> String {
		if let msgPtr = _errmsg(db) { return String(cString: msgPtr) }
		return "sqlite3 error (no message)"
	}

	/// Prepare a statement with optional parameter binding
	private static func prepare(sql: String, params: [AnyHashable]? = nil, db: OpaquePointer) throws -> OpaquePointer? {
		var stmt: OpaquePointer?
		let code = (sql as NSString).utf8String.map { _prepare_v2(db, $0, -1, &stmt, nil) } ?? SQLITE_OK

		guard !isErr(code) else {
			throw SQLiteError.queryFailed(detail: errMsg(db))
		}

		guard let s = stmt else { return nil }

		if let params {
			for (i, val) in params.enumerated() {
				bind(val, to: s, at: CInt(i + 1))
			}
		}

		return s
	}

	/// Bind a Swift value to a sqlite3 parameter position
	private static func bind(_ value: AnyHashable, to stmt: OpaquePointer, at idx: CInt) {
		if let intVal = value as? Int64 {
			_ = _bind_int64(stmt, idx, intVal)
		} else if let doubleVal = value as? Double {
			_ = _bind_double(stmt, idx, doubleVal)
		} else if let textVal = value as? String {
			if let utf = (textVal as NSString).utf8String {
				_ = _bind_text(stmt, idx, utf, -1, SQLITE_TRANSIENT)
			}
		} else if let blobVal = value as? Data {
			_ = blobVal.withUnsafeBytes { rawPtr in
				_bind_blob(stmt, idx, rawPtr.baseAddress, CInt(blobVal.count), SQLITE_TRANSIENT)
			}
		} else {
			let fallingStr = String(describing: value)
			if let utf = (fallingStr as NSString).utf8String {
				_ = _bind_text(stmt, idx, utf, -1, SQLITE_TRANSIENT)
			}
		}
	}

	/// Extract a column value from a row by type
	private static func colVal(stmt: OpaquePointer, col: CInt, type: CInt) -> Any? {
		switch type {
		case SQLITE_INTEGER:
			return _column_int64(stmt, col)
		case SQLITE_FLOAT:
			return _column_double(stmt, col)
		case SQLITE_TEXT:
			guard let txt = _column_text(stmt, col) else { return nil }
			return String(cString: txt)
		case SQLITE_BLOB:
			guard let blob = _column_blob(stmt, col) else { return nil }
			let len = Int(_column_bytes(stmt, col))
			guard len > 0 else { return nil }
			return Data(bytes: blob, count: len)
		case SQLITE_NULL:
			return nil
		default:
			return nil
		}
	}

	/// Execute DML/DDL
	private static func exec(sql: String, parameters: [AnyHashable]? = nil, db: OpaquePointer) throws {
		guard let stmt = try prepare(sql: sql, params: parameters, db: db) else { return }
		defer { _ = _finalize(stmt) }
		let result = _step(stmt)
		if result != SQLITE_DONE, result != SQLITE_ROW {
			throw SQLiteError.executionFailed(detail: errMsg(db))
		}
	}

	/// Fetch single scalar value
	private static func scalarQ(sql: String, parameters: [AnyHashable]? = nil, db: OpaquePointer) throws -> Any? {
		guard let stmt = try prepare(sql: sql, params: parameters, db: db) else { return nil }
		defer { _ = _finalize(stmt) }
		guard _step(stmt) == SQLITE_ROW else { return nil }
		let type = _column_type(stmt, 0)
		return colVal(stmt: stmt, col: 0, type: type)
	}

	/// Fetch multiple rows
	private static func query(sql: String, parameters: [AnyHashable]? = nil, db: OpaquePointer) throws -> [[String: Any]] {
		guard let stmt = try prepare(sql: sql, params: parameters, db: db) else { return [] }
		defer { _ = _finalize(stmt) }

		let colCount = Int(_column_count(stmt))
		var results: [[String: Any]] = []

		while _step(stmt) == SQLITE_ROW {
			var row: [String: Any] = [:]
			for i in 0 ..< colCount {
				let ci = CInt(i)
				guard let namePtr = _column_name(stmt, ci) else { continue }
				let name = String(cString: namePtr)
				let type = _column_type(stmt, ci)
				if let val = colVal(stmt: stmt, col: ci, type: type) {
					row[name] = val
				}
			}
			results.append(row)
		}

		return results
	}

	// MARK: - Schema

	private func ensureSchema(db: OpaquePointer) throws {
		try Self.exec(sql: """
		CREATE TABLE IF NOT EXISTS sessions (
		    id INTEGER PRIMARY KEY AUTOINCREMENT,
		    model_id TEXT NOT NULL,
		    created_at INTEGER NOT NULL,
		    updated_at INTEGER NOT NULL,
		    message_count INTEGER DEFAULT 0,
		    token_count INTEGER DEFAULT 0,
		    summary TEXT,
		    ttl_days INTEGER DEFAULT 180
		);
		""", db: db)

		try Self.exec(sql: """
		CREATE TABLE IF NOT EXISTS messages (
		    id INTEGER PRIMARY KEY AUTOINCREMENT,
		    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
		    role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system', 'tool')),
		    content TEXT NOT NULL,
		    created_at INTEGER NOT NULL,
		    token_count INTEGER DEFAULT 0,
		    tool_calls TEXT,
		    embed_vector BLOB
		);
		""", db: db)

		try Self.exec(sql: """
		CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
		    session_id UNINDEXED,
		    content,
		    content='messages',
		    content_rowid='id'
		);
		""", db: db)

		try Self.exec(sql: """
		CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
		    INSERT INTO messages_fts(rowid, session_id, content)
		    VALUES (new.id, new.session_id, new.content);
		END;
		""", db: db)

		try Self.exec(sql: """
		CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
		    INSERT INTO messages_fts(messages_fts, rowid, session_id, content)
		    VALUES ('delete', old.id, old.session_id, old.content);
		END;
		""", db: db)

		try Self.exec(sql: """
		CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
		    INSERT INTO messages_fts(messages_fts, rowid, session_id, content)
		    VALUES ('delete', old.id, old.session_id, old.content);
		    INSERT INTO messages_fts(rowid, session_id, content)
		    VALUES (new.id, new.session_id, new.content);
		END;
		""", db: db)

		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_id ON messages(session_id);", db: db)
		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);", db: db)
		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_model_id ON sessions(model_id);", db: db)
		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at);", db: db)

		// Structured memory events — six-element knowledge model (方案 B 单层)
		// 时间(timestamp), 地点(context), 人物(entities), 起因(cause), 经过(process), 结果(result)
		// SET NULL on session delete — events survive session TTL as permanent memory
		// memory_type drives retention: transient=purge, pattern/fact/preference=long-lived
		try Self.exec(sql: """
		CREATE TABLE IF NOT EXISTS memory_events (
		    id INTEGER PRIMARY KEY AUTOINCREMENT,
		    session_id INTEGER REFERENCES sessions(id) ON DELETE SET NULL,
		    timestamp INTEGER NOT NULL,
		    context TEXT NOT NULL,
		    entities TEXT,
		    cause TEXT,
		    process TEXT,
		    result TEXT,
		    resolution TEXT DEFAULT 'unresolved' CHECK(resolution IN ('resolved', 'workaround', 'unresolved')),
		    memory_type TEXT DEFAULT 'transient' CHECK(memory_type IN ('transient', 'pattern', 'fact', 'preference')),
		    dedup_key TEXT NOT NULL DEFAULT '',
		    confidence REAL DEFAULT 0.8 CHECK(confidence >= 0.0 AND confidence <= 1.0),
		    tags TEXT
		);
		""", db: db)

		try Self.exec(sql: """
		CREATE VIRTUAL TABLE IF NOT EXISTS memory_events_fts USING fts5(
		    session_id UNINDEXED,
		    cause,
		    process,
		    result,
		    content='memory_events',
		    content_rowid='id'
		);
		""", db: db)

		try Self.exec(sql: """
		CREATE TRIGGER IF NOT EXISTS memory_events_ai AFTER INSERT ON memory_events BEGIN
		    INSERT INTO memory_events_fts(rowid, session_id, cause, process, result)
		    VALUES (new.id, new.session_id, new.cause, new.process, new.result);
		END;
		""", db: db)

		try Self.exec(sql: """
		CREATE TRIGGER IF NOT EXISTS memory_events_ad AFTER DELETE ON memory_events BEGIN
		    INSERT INTO memory_events_fts(memory_events_fts, rowid, session_id, cause, process, result)
		    VALUES ('delete', old.id, old.session_id, old.cause, old.process, old.result);
		END;
		""", db: db)

		try Self.exec(sql: """
		CREATE TRIGGER IF NOT EXISTS memory_events_au AFTER UPDATE ON memory_events BEGIN
		    INSERT INTO memory_events_fts(memory_events_fts, rowid, session_id, cause, process, result)
		    VALUES ('delete', old.id, old.session_id, old.cause, old.process, old.result);
		    INSERT INTO memory_events_fts(rowid, session_id, cause, process, result)
		    VALUES (new.id, new.session_id, new.cause, new.process, new.result);
		END;
		""", db: db)

		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_memory_events_session ON memory_events(session_id);", db: db)
		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_memory_events_timestamp ON memory_events(timestamp);", db: db)
		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_memory_events_context ON memory_events(context);", db: db)
		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_memory_events_type ON memory_events(memory_type);", db: db)
		try Self.exec(sql: "CREATE INDEX IF NOT EXISTS idx_memory_events_confidence ON memory_events(confidence);", db: db)
		try Self.exec(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_events_dedup ON memory_events(dedup_key);", db: db)
	}
}

/// Type-safe enum representing SQLite column values.
///
/// Replaces the previous ``@unchecked Sendable`` wrapper because every stored
/// case member (`Int64`, `Double`, `String`, `Data`) is itself `Sendable`,
/// allowing the Swift compiler to verify cross-actor safety automatically.
///
/// The set of cases mirrors SQLite's five column types:
/// - ``integer`` → SQLITE_INTEGER
/// - ``float``   → SQLITE_FLOAT
/// - ``text``   → SQLITE_TEXT
/// - ``blob``      → SQLITE_BLOB
/// - ``null``      → SQLITE_NULL
///
/// Consumers switch on the enum (or use the convenience `as*` computed
/// properties) to extract the strongly-typed value — no `as?` runtime casts needed.
public enum SendableValue: Sendable {
	case integer(Int64)
	case float(Double)
	case text(String)
	case blob(Data)
	case null

	// MARK: - Failable init for backward compatibility with `wrap()` / `wrapRows()`

	/// Construct from any `SQLite` scalar (`Int64`, `Double`, `String`, `Data`, `nil`).
	/// - Note: Prefer type-switching the query result directly rather than
	///   routing through this raw-value initializer.
	@_disfavoredOverload
	init(rawValue value: Any) {
		switch value {
		case let v as Int64:
			self = .integer(v)
		case let v as Int:
			self = .integer(Int64(v))
		case let v as UInt64:
			self = .integer(Int64(truncatingIfNeeded: v))
		case let v as Double:
			self = .float(v)
		case let v as Float:
			self = .float(Double(v))
		case let v as String:
			self = .text(v)
		case let v as Data:
			self = .blob(v)
		case is NSNull:
			self = .null
		default:
			// Defensive fallback — SQLite never produces this path, but
			// we must handle the non-exhaustive switch for type-safety.
			self = .null
		}
	}

	// MARK: - Convenience casting (preserves backward compatibility)

	/// Extract as ``Int64`` if this is the ``integer`` case.
	var asInt64: Int64? {
		if case let .integer(v) = self { return v }
		return nil
	}

	/// Extract as ``Double`` if this is the ``float`` case.
	var asDouble: Double? {
		if case let .float(v) = self { return v }
		return nil
	}

	/// Extract as ``String`` if this is the ``text`` case.
	var asString: String? {
		if case let .text(v) = self { return v }
		return nil
	}

	/// Extract as ``Data`` if this is the ``blob`` case.
	var asData: Data? {
		if case let .blob(v) = self { return v }
		return nil
	}

	/// Legacy accessor for backward compatibility with ``rawValue`` casts used in
	/// ``SessionModel`` (`messageCount`, `tokenCount`, `ttlDays`).
	///
	/// - Note: Prefer switching on ``SendableValue`` cases or using the
	///   convenience ``asInt64``, ``asDouble``, ``asString``, ``asData`` properties.
	var rawValue: Any {
		switch self {
		case let .integer(v): v
		case let .float(v): v
		case let .text(v): v
		case let .blob(v): v
		case .null: NSNull()
		}
	}
}

// MARK: - SQLite Error Type

enum SQLiteError: Error {
	case notConnected
	case connectionFailed(detail: String)
	case queryFailed(detail: String)
	case executionFailed(detail: String)
	case schemaMigrationFailed(detail: String)
}

extension SQLiteError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case .notConnected: "SQLite database not connected"
		case let .connectionFailed(detail): "Connection failed: \(detail)"
		case let .queryFailed(detail): "Query failed: \(detail)"
		case let .executionFailed(detail): "Execution failed: \(detail)"
		case let .schemaMigrationFailed(detail): "Schema migration failed: \(detail)"
		}
	}
}
