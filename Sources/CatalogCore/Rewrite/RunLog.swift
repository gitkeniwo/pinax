import Foundation
import GRDB

/// What kind of work a run did.
public enum RunKind: String, Codable, Equatable, Sendable {
  case rewrite
  case domainMigrate = "domain_migrate"
  case externalMigrate = "external_migrate"
  /// Recompressing a backend's objects at the same keys.
  case optimize
}

public enum RunState: String, Codable, Equatable, Sendable {
  case running, finished, failed, interrupted
  /// Stopped by the person.
  case cancelled
}

public enum RunLevel: String, Codable, Equatable, Sendable, Comparable {
  case info, warning, error

  private var rank: Int {
    switch self {
    case .info: return 0
    case .warning: return 1
    case .error: return 2
    }
  }

  public static func < (lhs: RunLevel, rhs: RunLevel) -> Bool { lhs.rank < rhs.rank }
}

/// One `run` row. `params` and `summary` are the stored JSON.
public struct RunRecord: Equatable, Sendable {
  public let id: Int64
  public let kind: RunKind
  public let backendID: Int64?
  public internal(set) var state: RunState
  public let dryRun: Bool
  public let fromRunID: Int64?
  public let pid: Int32?
  public let startedAt: String
  public let finishedAt: String?
  public let params: String
  public let summary: String?

  init(row: Row) throws {
    id = row["id"]
    let kindValue: String = row["kind"]
    guard let kind = RunKind(rawValue: kindValue) else { throw RunLogError.corrupt("kind \(kindValue)") }
    self.kind = kind
    backendID = row["backend_id"]
    let stateValue: String = row["state"]
    guard let state = RunState(rawValue: stateValue) else {
      throw RunLogError.corrupt("state \(stateValue)")
    }
    self.state = state
    dryRun = row["dry_run"]
    fromRunID = row["from_run_id"]
    pid = row["pid"]
    startedAt = row["started_at"]
    finishedAt = row["finished_at"]
    params = row["params"]
    summary = row["summary"]
  }
}

/// One stored event with its place in the run. Encodes as the raw log line
/// `{seq, at, level, type, data}`.
public struct RunEventRecord: Equatable, Sendable, Encodable {
  public let seq: Int
  public let at: String
  public let level: RunLevel
  public let event: RunEvent

  public init(seq: Int, at: String, level: RunLevel, event: RunEvent) {
    self.seq = seq
    self.at = at
    self.level = level
    self.event = event
  }

  enum CodingKeys: String, CodingKey { case seq, at, level, type, data }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(seq, forKey: .seq)
    try container.encode(at, forKey: .at)
    try container.encode(level, forKey: .level)
    try event.encodeTypeAndData(into: &container, type: .type, data: .data)
  }

  /// One JSONL line, keys sorted.
  public var jsonLine: String {
    // Every payload is plain strings and numbers; encoding cannot fail.
    String(decoding: (try? RunLog.encoder.encode(self)) ?? Data(), as: UTF8.self)
  }
}

public enum RunLogError: Error, Equatable, CustomStringConvertible {
  case corrupt(String)
  case unknownEventType(String)

  public var description: String {
    switch self {
    case let .corrupt(what): return "The run log holds an unreadable \(what)."
    case let .unknownEventType(type): return "The run log holds an unknown event type \(type)."
    }
  }
}

/// The `run` and `run_event` tables.
public enum RunLog {
  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  static func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// Starts a run in state `running` with this process's pid.
  public static func start(
    kind: RunKind, backendID: Int64? = nil, dryRun: Bool, fromRunID: Int64? = nil,
    params: some Encodable, in database: CatalogDatabasePool, now: Date = Date()
  ) throws -> Int64 {
    let paramsJSON = try json(params)
    return try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO run (kind, backend_id, state, dry_run, from_run_id, pid, started_at, params)
          VALUES (?, ?, 'running', ?, ?, ?, ?, ?)
          """,
        arguments: [
          kind.rawValue, backendID, dryRun, fromRunID, Int64(getpid()), timestamp(now), paramsJSON,
        ])
      return db.lastInsertedRowID
    }
  }

  /// Appends `event` with the next `seq` of the run.
  @discardableResult
  public static func append(
    _ event: RunEvent, to runID: Int64, in database: CatalogDatabasePool, now: Date = Date()
  ) throws -> RunEventRecord {
    let data = try event.dataJSON()
    let at = timestamp(now)
    return try database.write { db in
      let seq =
        try Int.fetchOne(
          db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM run_event WHERE run_id = ?",
          arguments: [runID]) ?? 1
      try db.execute(
        sql: "INSERT INTO run_event (run_id, seq, at, level, type, data) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [runID, seq, at, event.level.rawValue, event.type, data])
      return RunEventRecord(seq: seq, at: at, level: event.level, event: event)
    }
  }

  public static func finish(
    _ runID: Int64, state: RunState, summary: some Encodable, in database: CatalogDatabasePool,
    now: Date = Date()
  ) throws {
    let summaryJSON = try json(summary)
    try database.write { db in
      try db.execute(
        sql: "UPDATE run SET state = ?, finished_at = ?, summary = ? WHERE id = ?",
        arguments: [state.rawValue, timestamp(now), summaryJSON, runID])
    }
  }

  /// Ends a run that stopped on an error, keeping whatever summary it has.
  public static func fail(_ runID: Int64, in database: CatalogDatabasePool, now: Date = Date()) {
    try? database.write { db in
      try db.execute(
        sql: "UPDATE run SET state = 'failed', finished_at = ? WHERE id = ? AND state = 'running'",
        arguments: [timestamp(now), runID])
    }
  }

  /// Whether a process with this pid exists.
  public static func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  /// Runs, newest first. A `running` run whose process is gone becomes
  /// `interrupted` here, in the table.
  public static func runs(
    limit: Int? = nil, in database: CatalogDatabasePool,
    processExists: (Int32) -> Bool = processExists
  ) throws -> [RunRecord] {
    try markInterrupted(in: database, processExists: processExists)
    return try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM run ORDER BY started_at DESC, id DESC LIMIT ?",
        arguments: [limit ?? -1]
      ).map(RunRecord.init(row:))
    }
  }

  /// Runs, newest first, without touching the table: a `running` run
  /// whose process is gone reads as `interrupted` (as `runs` would mark it)
  /// but stays as stored — the activity panel's read.
  public static func listedRuns(
    limit: Int? = nil, in database: CatalogDatabasePool,
    processExists: (Int32) -> Bool = processExists
  ) throws -> [RunRecord] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM run ORDER BY started_at DESC, id DESC LIMIT ?",
        arguments: [limit ?? -1]
      ).map(RunRecord.init(row:))
    }.map { run in
      guard run.state == .running, run.pid.map({ !processExists($0) }) ?? true else { return run }
      var shown = run
      shown.state = .interrupted
      return shown
    }
  }

  public static func run(
    _ id: Int64, in database: CatalogDatabasePool,
    processExists: (Int32) -> Bool = processExists
  ) throws -> RunRecord? {
    try markInterrupted(in: database, processExists: processExists)
    return try database.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM run WHERE id = ?", arguments: [id])
        .map(RunRecord.init(row:))
    }
  }

  public static func events(of runID: Int64, in database: CatalogDatabasePool) throws -> [RunEventRecord] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT seq, at, level, type, data FROM run_event WHERE run_id = ? ORDER BY seq",
        arguments: [runID]
      ).map(eventRecord(row:))
    }
  }

  /// The events of a run after `seq`, in order — the activity panel's
  /// incremental read. Read-only.
  public static func events(
    of runID: Int64, after seq: Int, in database: CatalogDatabasePool
  ) throws -> [RunEventRecord] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT seq, at, level, type, data FROM run_event WHERE run_id = ? AND seq > ? ORDER BY seq",
        arguments: [runID, seq]
      ).map(eventRecord(row:))
    }
  }

  static func eventRecord(row: Row) throws -> RunEventRecord {
    let levelValue: String = row["level"]
    guard let level = RunLevel(rawValue: levelValue) else {
      throw RunLogError.corrupt("level \(levelValue)")
    }
    return RunEventRecord(
      seq: row["seq"], at: row["at"], level: level,
      event: try RunEvent(type: row["type"], data: row["data"]))
  }

  private static func markInterrupted(
    in database: CatalogDatabasePool, processExists: (Int32) -> Bool
  ) throws {
    let running = try database.read { db in
      try Row.fetchAll(db, sql: "SELECT id, pid FROM run WHERE state = 'running'")
        .map { (id: $0["id"] as Int64, pid: $0["pid"] as Int32?) }
    }
    let gone = running.filter { run in run.pid.map { !processExists($0) } ?? true }
    guard !gone.isEmpty else { return }
    try database.write { db in
      for run in gone {
        try db.execute(
          sql: "UPDATE run SET state = 'interrupted' WHERE id = ? AND state = 'running'",
          arguments: [run.id])
      }
    }
  }
}
