import Foundation

/// Glob matching over relative POSIX paths, for a project
/// source's include and exclude patterns. Case-sensitive.
///
/// - `*` matches any run of characters within one path segment.
/// - `**` as a whole segment matches zero or more segments, so `**/x`
///   also matches `x`; anywhere else it is a `*`.
/// - `?` matches one character other than `/`.
/// - `{a,b}` matches either alternative; braces do not nest. A `{` without
///   a closing `}` is a literal.
public enum PathGlob {
  public static func matches(_ pattern: String, _ path: String) -> Bool {
    let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(Array.init)
    return expandBraces(pattern).contains { alternative in
      let parts = alternative.split(separator: "/", omittingEmptySubsequences: false).map(Array.init)
      return match(parts[...], segments[...])
    }
  }

  /// True when `path` matches any of `patterns`.
  public static func matchesAny(_ patterns: [String], _ path: String) -> Bool {
    patterns.contains { matches($0, path) }
  }

  static func expandBraces(_ pattern: String) -> [String] {
    guard let open = pattern.firstIndex(of: "{"),
      let close = pattern[open...].firstIndex(of: "}")
    else { return [pattern] }
    let head = pattern[..<open]
    let body = pattern[pattern.index(after: open)..<close]
    let tail = String(pattern[pattern.index(after: close)...])
    let tails = expandBraces(tail)
    return body.split(separator: ",", omittingEmptySubsequences: false).flatMap { choice in
      tails.map { head + choice + $0 }
    }
  }

  private static func match(_ parts: ArraySlice<[Character]>, _ segments: ArraySlice<[Character]>)
    -> Bool
  {
    guard let part = parts.first else { return segments.isEmpty }
    if part == ["*", "*"] {
      let rest = parts.dropFirst()
      var remaining = segments
      while true {
        if match(rest, remaining) { return true }
        guard !remaining.isEmpty else { return false }
        remaining = remaining.dropFirst()
      }
    }
    guard let segment = segments.first, matchSegment(part[...], segment[...]) else { return false }
    return match(parts.dropFirst(), segments.dropFirst())
  }

  private static func matchSegment(_ pattern: ArraySlice<Character>, _ text: ArraySlice<Character>)
    -> Bool
  {
    guard let head = pattern.first else { return text.isEmpty }
    switch head {
    case "*":
      let rest = pattern.drop(while: { $0 == "*" })
      var remaining = text
      while true {
        if matchSegment(rest, remaining) { return true }
        guard !remaining.isEmpty else { return false }
        remaining = remaining.dropFirst()
      }
    case "?":
      guard !text.isEmpty else { return false }
      return matchSegment(pattern.dropFirst(), text.dropFirst())
    default:
      guard text.first == head else { return false }
      return matchSegment(pattern.dropFirst(), text.dropFirst())
    }
  }
}
