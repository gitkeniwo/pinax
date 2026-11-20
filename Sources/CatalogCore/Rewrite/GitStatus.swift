import Foundation

/// Whether a source folder can be written without a
/// backup. Anything but `.clean` has to be allowed before a rewrite writes
/// to it.
public enum SourceGitStatus: Equatable, Sendable {
  case clean
  case notGit
  /// Modified, staged or untracked paths under the source, as `git status`
  /// prints them.
  case dirty(paths: [String])
  case unknown(reason: String)

  public var isClean: Bool { self == .clean }
}

public protocol GitStatusProviding: Sendable {
  func status(of root: URL) -> SourceGitStatus
}

/// Looks for `.git` (a folder, or a worktree's file) from the source folder
/// upward and only then runs `/usr/bin/git status`, limited to the source
/// folder. Without `.git` no process starts: on a Mac without the command
/// line tools, running `git` opens an install prompt.
public struct GitStatusProvider: GitStatusProviding {
  public static let timeout: TimeInterval = 10

  public var gitPath: String
  public var timeout: TimeInterval

  public init(gitPath: String = "/usr/bin/git", timeout: TimeInterval = Self.timeout) {
    self.gitPath = gitPath
    self.timeout = timeout
  }

  public func status(of root: URL) -> SourceGitStatus {
    guard Self.containingRepository(root) != nil else { return .notGit }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gitPath)
    process.arguments = [
      "-C", root.path, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", ".",
    ]
    var environment = ProcessInfo.processInfo.environment
    // A status that refreshes the index would write inside the repository.
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    let collected = OutputBox()
    let reading = DispatchGroup()
    for (pipe, isError) in [(output, false), (errors, true)] {
      reading.enter()
      DispatchQueue.global().async {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        collected.set(data, isError: isError)
        reading.leave()
      }
    }
    do {
      try process.run()
    } catch {
      try? output.fileHandleForWriting.close()
      try? errors.fileHandleForWriting.close()
      return .unknown(reason: error.localizedDescription)
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = finished.wait(timeout: .now() + 1)
      return .unknown(reason: "git status did not finish within \(Int(timeout)) s")
    }
    reading.wait()
    guard process.terminationStatus == 0 else {
      let message = String(decoding: collected.errors, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return .unknown(
        reason: message.isEmpty ? "git status exited with \(process.terminationStatus)" : message)
    }
    let paths = Self.parsePorcelain(collected.output)
    return paths.isEmpty ? .clean : .dirty(paths: paths)
  }

  /// The folder holding `.git` at or above `root`, or nil.
  static func containingRepository(_ root: URL) -> URL? {
    var directory = root.standardizedFileURL.path
    while true {
      if FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".git")) {
        return URL(fileURLWithPath: directory, isDirectory: true)
      }
      // `URL("/").deletingLastPathComponent()` is `/..`, never `/`; the
      // string form stops at the root.
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory || parent.isEmpty { return nil }
      directory = parent
    }
  }

  /// The paths in `git status --porcelain=v1 -z` output. A rename or copy
  /// entry is followed by its original path, which is left out.
  static func parsePorcelain(_ data: Data) -> [String] {
    var paths: [String] = []
    var fields = data.split(separator: 0, omittingEmptySubsequences: true).makeIterator()
    while let field = fields.next() {
      guard field.count > 3 else { continue }
      let status = field.prefix(2)
      paths.append(String(decoding: field.dropFirst(3), as: UTF8.self))
      if status.contains(UInt8(ascii: "R")) || status.contains(UInt8(ascii: "C")) {
        _ = fields.next()
      }
    }
    return paths
  }
}

private final class OutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedOutput = Data()
  private var storedErrors = Data()

  func set(_ data: Data, isError: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if isError { storedErrors = data } else { storedOutput = data }
  }

  var output: Data {
    lock.lock()
    defer { lock.unlock() }
    return storedOutput
  }

  var errors: Data {
    lock.lock()
    defer { lock.unlock() }
    return storedErrors
  }
}
