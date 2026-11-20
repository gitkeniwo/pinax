import Foundation

/// One URL rewrite. `exact` replaces one whole decoded
/// URL, query and fragment included; `prefix` moves everything under one
/// URL prefix to another, carrying the rest of the URL across unchanged.
public enum RewriteRule: Equatable, Hashable, Sendable {
  case exact(from: String, to: String)
  case prefix(from: String, to: String)

  public var from: String {
    switch self {
    case let .exact(from, _), let .prefix(from, _): return from
    }
  }

  public var to: String {
    switch self {
    case let .exact(_, to), let .prefix(_, to): return to
    }
  }

  public var isPrefix: Bool {
    if case .prefix = self { return true }
    return false
  }

  /// `url` rewritten by this rule, or nil when the rule does not match it.
  public func rewrite(_ url: String) -> String? {
    switch self {
    case let .exact(from, to):
      return url == from ? to : nil
    case let .prefix(from, to):
      let base = RewriteRules.trimmingTrailingSlashes(from)
      guard RewriteRules.isUnder(url, prefix: base) else { return nil }
      return RewriteRules.trimmingTrailingSlashes(to) + url.dropFirst(base.count)
    }
  }
}

/// Why a rule table cannot be planned with.
public enum RewriteRuleProblem: Equatable, Sendable, CustomStringConvertible {
  case empty
  /// Two rules of the same kind with the same `from` (prefixes compared
  /// without their trailing `/`, scheme and host ignoring case).
  case duplicateFrom(String)
  case unchanged(index: Int)
  /// `from` or `to` is not an absolute http(s) URL with a host; a prefix
  /// rule's URLs also may not carry a query or fragment.
  case notHTTPURL(index: Int, url: String)
  /// What rule `index` writes would be matched again by rule `by`.
  case chained(index: Int, by: Int)

  public var description: String {
    switch self {
    case .empty:
      return "No rewrite rules."
    case let .duplicateFrom(from):
      return "More than one rule rewrites \(from)."
    case let .unchanged(index):
      return "Rule \(index + 1) rewrites a URL to itself."
    case let .notHTTPURL(index, url):
      return "Rule \(index + 1): \(url) is not an absolute http(s) URL."
    case let .chained(index, by):
      return "Rule \(index + 1) writes URLs that rule \(by + 1) would rewrite again."
    }
  }
}

public enum RewriteRules {
  /// Every problem in `rules`, in rule order; empty means the table is
  /// usable.
  public static func validate(_ rules: [RewriteRule]) -> [RewriteRuleProblem] {
    guard !rules.isEmpty else { return [.empty] }
    var problems: [RewriteRuleProblem] = []
    var seen = Set<String>()
    var reported = Set<String>()
    for (index, rule) in rules.enumerated() {
      for url in [rule.from, rule.to] where !isHTTPURL(url, bare: rule.isPrefix) {
        problems.append(.notHTTPURL(index: index, url: url))
      }
      let identity = (rule.isPrefix ? "p " : "e ") + normalized(rule.from, prefix: rule.isPrefix)
      if !seen.insert(identity).inserted, reported.insert(identity).inserted {
        problems.append(.duplicateFrom(rule.from))
      }
      if normalized(rule.from, prefix: rule.isPrefix) == normalized(rule.to, prefix: rule.isPrefix)
      {
        problems.append(.unchanged(index: index))
      }
    }
    guard problems.isEmpty else { return problems }
    for (index, rule) in rules.enumerated() {
      if let by = rules.indices.first(where: { chains(rule, into: rules[$0]) }) {
        problems.append(.chained(index: index, by: by))
      }
    }
    return problems
  }

  /// The rule that rewrites `url` and what it writes: an exact rule first,
  /// then the prefix rule with the longest `from`.
  public static func match(_ url: String, in rules: [RewriteRule]) -> (index: Int, url: String)? {
    if let index = rules.firstIndex(where: { !$0.isPrefix && $0.from == url }) {
      return (index, rules[index].to)
    }
    var best: (index: Int, url: String, length: Int)?
    for (index, rule) in rules.enumerated() where rule.isPrefix {
      let length = trimmingTrailingSlashes(rule.from).count
      if let rewritten = rule.rewrite(url), length > best?.length ?? -1 {
        best = (index, rewritten, length)
      }
    }
    return best.map { ($0.index, $0.url) }
  }

  // MARK: - Helpers

  /// Whether something `rule` writes could be matched by `other`.
  private static func chains(_ rule: RewriteRule, into other: RewriteRule) -> Bool {
    switch (rule, other) {
    case let (.exact(_, to), _):
      return other.rewrite(to) != nil
    case let (.prefix(_, to), .exact(from, _)):
      return isUnder(from, prefix: trimmingTrailingSlashes(to))
    case let (.prefix(_, to), .prefix(from, _)):
      // Written URLs are `to/…`; `from/…` catches some of them when either
      // prefix sits under (or is) the other.
      let written = trimmingTrailingSlashes(to)
      let caught = trimmingTrailingSlashes(from)
      return isUnder(written + "/", prefix: caught) || isUnder(caught + "/", prefix: written)
    }
  }

  /// Whether `url` starts with `prefix + "/"`, comparing the scheme and host
  /// without regard to case and the rest exactly. `prefix` has no trailing
  /// `/`.
  static func isUnder(_ url: String, prefix: String) -> Bool {
    let urlBytes = Array(url.utf8)
    let prefixBytes = Array(prefix.utf8)
    guard urlBytes.count > prefixBytes.count, urlBytes[prefixBytes.count] == UInt8(ascii: "/")
    else { return false }
    let origin = originLength(prefix)
    for offset in 0..<prefixBytes.count {
      let lhs = urlBytes[offset]
      let rhs = prefixBytes[offset]
      if offset < origin {
        if lowercased(lhs) != lowercased(rhs) { return false }
      } else if lhs != rhs {
        return false
      }
    }
    return true
  }

  static func trimmingTrailingSlashes(_ value: String) -> String {
    var result = value
    while result.last == "/" { result.removeLast() }
    return result
  }

  /// The UTF-8 length of `scheme://authority`.
  static func originLength(_ value: String) -> Int {
    guard let separator = value.range(of: "://") else { return 0 }
    let end = value[separator.upperBound...].firstIndex(of: "/") ?? value.endIndex
    return value.utf8.distance(from: value.startIndex, to: end)
  }

  private static func lowercased(_ byte: UInt8) -> UInt8 {
    (65...90).contains(byte) ? byte + 32 : byte
  }

  private static func normalized(_ url: String, prefix: Bool) -> String {
    let value = prefix ? trimmingTrailingSlashes(url) : url
    let bytes = Array(value.utf8)
    let origin = originLength(value)
    return String(decoding: bytes[..<origin].map(lowercased), as: UTF8.self)
      + String(decoding: bytes[origin...], as: UTF8.self)
  }

  private static func isHTTPURL(_ url: String, bare: Bool) -> Bool {
    guard let components = URLComponents(string: url),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      url.lowercased().hasPrefix(scheme + "://")
    else { return false }
    return !bare || (components.query == nil && components.fragment == nil)
  }
}
