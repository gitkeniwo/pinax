import Darwin
import Foundation

public enum CommandSourceError: Error, Equatable, CustomStringConvertible {
  /// The caller's policy did not allow the command; nothing ran.
  case commandNotAllowed(label: String)
  case workingDirectoryNotFound(label: String, path: String)
  /// `status` is the exit status, or the signal that ended the command.
  case commandFailed(label: String, status: Int32, stderrTail: String)
  case commandTimedOut(label: String, seconds: TimeInterval)
  case commandOutputTooLarge(label: String)
  /// `field` names what in the output does not fit the contract.
  case commandOutputInvalid(label: String, field: String)

  public var description: String {
    switch self {
    case let .commandNotAllowed(label):
      return "Source '\(label)' runs a command that has not been allowed to run."
    case let .workingDirectoryNotFound(label, path):
      return "Source '\(label)' working directory not found: \(path)"
    case let .commandFailed(label, status, stderrTail):
      let line = "Source '\(label)' command failed with status \(status)."
      return stderrTail.isEmpty ? line : line + "\n" + stderrTail
    case let .commandTimedOut(label, seconds):
      return
        "Source '\(label)' command did not finish within \(String(format: "%g", seconds)) seconds."
    case let .commandOutputTooLarge(label):
      return "Source '\(label)' command printed too much output."
    case let .commandOutputInvalid(label, field):
      return "Source '\(label)' command output is invalid at '\(field)'."
    }
  }
}

/// Which command sources a scan may run. A command travels with the catalog,
/// so the caller decides; the catalog itself never allows one.
public struct CommandSourcePolicy: Sendable {
  private let decide: @Sendable (ProjectSource) -> Bool

  public init(allows: @escaping @Sendable (ProjectSource) -> Bool) {
    decide = allows
  }

  public func allows(_ source: ProjectSource) -> Bool { decide(source) }

  public static let deny = CommandSourcePolicy { _ in false }
  public static let allow = CommandSourcePolicy { _ in true }
}

/// One run of a command source's command.
public struct CommandSourceRequest: Equatable, Sendable {
  public var label: String
  public var command: String
  public var workingDirectory: String
  /// Added to this process's environment.
  public var environment: [String: String]

  public init(
    label: String, command: String, workingDirectory: String, environment: [String: String] = [:]
  ) {
    self.label = label
    self.command = command
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public protocol CommandSourceRunning: Sendable {
  /// What the command printed to standard output. Throws
  /// `CommandSourceError` when it does not succeed.
  func run(_ request: CommandSourceRequest) throws -> Data
}

/// Runs a command with the user's login shell, so that what works in their
/// terminal is found here too. Standard input is empty. The command gets its
/// own process group, and the whole group is ended when it runs out of time
/// or prints too much.
public struct ShellCommandRunner: CommandSourceRunning {
  public static let defaultTimeout: TimeInterval = 120
  public static let defaultMaximumOutput = 64 * 1024 * 1024
  /// How much of standard error a failure reports.
  public static let errorTailLength = 4 * 1024
  /// How long the group has to end after SIGTERM before SIGKILL.
  static let killDelay: TimeInterval = 2

  /// Nil means `$SHELL`, or `/bin/zsh` when that is empty.
  public var shell: String?
  public var timeout: TimeInterval
  public var maximumOutput: Int

  public init(
    shell: String? = nil, timeout: TimeInterval = Self.defaultTimeout,
    maximumOutput: Int = Self.defaultMaximumOutput
  ) {
    self.shell = shell
    self.timeout = timeout
    self.maximumOutput = maximumOutput
  }

  public func run(_ request: CommandSourceRequest) throws -> Data {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: request.workingDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CommandSourceError.workingDirectoryNotFound(
        label: request.label, path: request.workingDirectory)
    }

    var environment = ProcessInfo.processInfo.environment
    environment.merge(request.environment) { _, added in added }
    let loginShell = shell ?? environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    environment["PWD"] = request.workingDirectory

    let process = Process()
    process.executableURL = URL(fileURLWithPath: loginShell)
    process.arguments = ["-l", "-c", request.command]
    process.currentDirectoryURL = URL(
      fileURLWithPath: request.workingDirectory, isDirectory: true)
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do {
      try process.run()
    } catch {
      throw CommandSourceError.commandFailed(
        label: request.label, status: 127, stderrTail: error.localizedDescription)
    }

    var collected = Data()
    var errorTail = Data()
    var streams = [
      pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
      pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
    ]
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let deadline = Self.now() + timeout
    var exitedAt: TimeInterval?
    // Done when the command has exited and its output has ended. Standard
    // error only gets a moment more: something left running may hold it.
    while true {
      if !process.isRunning {
        if exitedAt == nil { exitedAt = Self.now() }
        if streams[0].fd < 0, streams[1].fd < 0 || Self.now() - (exitedAt ?? 0) > 0.5 { break }
      }
      if Self.now() >= deadline {
        Self.end(process)
        throw CommandSourceError.commandTimedOut(label: request.label, seconds: timeout)
      }
      // A negative descriptor is skipped, so a closed stream just waits.
      guard poll(&streams, nfds_t(streams.count), 20) > 0 else { continue }
      for index in streams.indices where streams[index].fd >= 0 && streams[index].revents != 0 {
        let count = buffer.withUnsafeMutableBytes {
          read(streams[index].fd, $0.baseAddress, $0.count)
        }
        if count <= 0 {
          if count < 0, errno == EINTR || errno == EAGAIN { continue }
          streams[index].fd = -1
        } else if index == 0 {
          collected.append(contentsOf: buffer[0..<count])
          if collected.count > maximumOutput {
            Self.end(process)
            throw CommandSourceError.commandOutputTooLarge(label: request.label)
          }
        } else {
          errorTail.append(contentsOf: buffer[0..<count])
          if errorTail.count > Self.errorTailLength {
            errorTail = Data(errorTail.suffix(Self.errorTailLength))
          }
        }
      }
    }

    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw CommandSourceError.commandFailed(
        label: request.label, status: process.terminationStatus,
        stderrTail: String(decoding: errorTail, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return collected
  }

  private static func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  /// SIGTERM to the command's process group, then SIGKILL to whatever of it
  /// is left after `killDelay`.
  private static func end(_ process: Process) {
    let pid = process.processIdentifier
    // `Process` starts its child in a new group. Never signal our own.
    let ownsGroup = pid > 1 && pid != getpgrp() && getpgid(pid) != getpgrp()
    let target = ownsGroup ? -pid : pid
    _ = kill(target, SIGTERM)
    let deadline = now() + killDelay
    // `isRunning` also reaps the child, without which the group looks alive.
    while now() < deadline, process.isRunning || kill(target, 0) == 0 {
      usleep(20_000)
    }
    _ = kill(target, SIGKILL)
  }
}

/// What a command source's command prints:
/// `{"schema": 1, "refs": [{"raw_url", "source_ref", "kind"?}], "source_rev"?, "project"?}`.
/// A document made for `pinax usage sync` fits as it is.
struct CommandSourceOutput: Equatable {
  var references: [UsageReference]
  var sourceRevision: String?

  /// Reads `data` for the source `label` of `project`. References keep the
  /// `source_ref` the command gave; a missing `kind` reads as `text`.
  static func parse(_ data: Data, label: String, project: String) throws -> CommandSourceOutput {
    func invalid(_ field: String) -> CommandSourceError {
      .commandOutputInvalid(label: label, field: field)
    }
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw invalid("document")
    }
    guard let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
      schema.doubleValue == 1
    else { throw invalid("schema") }
    /// A key that may be left out; `null` counts as left out.
    func optionalString(_ object: [String: Any], _ key: String, _ field: String) throws -> String? {
      guard let value = object[key], !(value is NSNull) else { return nil }
      guard let string = value as? String else { throw invalid(field) }
      return string
    }
    if let named = try optionalString(object, "project", "project"), named != project {
      throw invalid("project")
    }
    let revision = try optionalString(object, "source_rev", "source_rev")
    guard let items = object["refs"] as? [Any] else { throw invalid("refs") }
    let references = try items.enumerated().map { index, item -> UsageReference in
      let path = "refs[\(index)]"
      guard let item = item as? [String: Any] else { throw invalid(path) }
      guard let rawURL = item["raw_url"] as? String, !rawURL.isEmpty else {
        throw invalid(path + ".raw_url")
      }
      guard let reference = item["source_ref"] as? String, !reference.isEmpty,
        !reference.hasPrefix("/")
      else { throw invalid(path + ".source_ref") }
      let kind = try optionalString(item, "kind", path + ".kind") ?? "text"
      guard !kind.isEmpty else { throw invalid(path + ".kind") }
      return UsageReference(rawURL: rawURL, sourceReference: reference, kind: kind)
    }
    return CommandSourceOutput(
      references: references, sourceRevision: revision.flatMap { $0.isEmpty ? nil : $0 })
  }
}
