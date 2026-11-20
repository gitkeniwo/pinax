import Foundation

/// A unified diff between two texts, line by line, in the
/// format `git diff` prints. A last line without a newline is marked
/// `\ No newline at end of file`.
public enum RewriteDiff {
  public static func unified(
    label: String, path: String, old: String, new: String, context: Int = 3
  ) -> String {
    let a = lines(old)
    let b = lines(new)
    guard a != b else { return "" }
    let script = editScript(a, b)
    var output = "--- a/\(label)/\(path)\n+++ b/\(label)/\(path)\n"
    for hunk in hunks(script, context: context) {
      let slice = script[hunk]
      let oldLines = slice.filter { $0.kind != .insert }
      let newLines = slice.filter { $0.kind != .delete }
      let oldStart = slice.first.map { $0.oldIndex } ?? 0
      let newStart = slice.first.map { $0.newIndex } ?? 0
      output +=
        "@@ -\(range(start: oldStart, count: oldLines.count)) "
        + "+\(range(start: newStart, count: newLines.count)) @@\n"
      for step in slice {
        let line: Line
        switch step.kind {
        case .equal:
          line = a[step.oldIndex]
          output += " "
        case .delete:
          line = a[step.oldIndex]
          output += "-"
        case .insert:
          line = b[step.newIndex]
          output += "+"
        }
        output += line.text + "\n"
        if !line.terminated { output += "\\ No newline at end of file\n" }
      }
    }
    return output
  }

  struct Line: Equatable {
    let text: String
    let terminated: Bool
  }

  enum Kind { case equal, delete, insert }

  /// One line of the edit script. `oldIndex` / `newIndex` are where the
  /// step sits in each text (for an insert, `oldIndex` is the next old line).
  struct Step {
    let kind: Kind
    let oldIndex: Int
    let newIndex: Int
  }

  static func lines(_ text: String) -> [Line] {
    var result = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      Line(text: String($0), terminated: true)
    }
    if result.last?.text.isEmpty == true {
      result.removeLast()
    } else if let last = result.popLast() {
      result.append(Line(text: last.text, terminated: false))
    }
    return result
  }

  /// "start,count" with git's conventions: 1-based, `,1` left out, and an
  /// empty range named by the line before it.
  private static func range(start: Int, count: Int) -> String {
    switch count {
    case 0: return "\(start),0"
    case 1: return "\(start + 1)"
    default: return "\(start + 1),\(count)"
    }
  }

  /// Index ranges into `script` covering every change plus `context`
  /// equal lines each side; changes closer than twice the context share
  /// one hunk.
  private static func hunks(_ script: [Step], context: Int) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for (index, step) in script.enumerated() where step.kind != .equal {
      let lower = max(0, index - context)
      let upper = min(script.count, index + context + 1)
      if let last = result.last, lower <= last.upperBound {
        result[result.count - 1] = last.lowerBound..<max(last.upperBound, upper)
      } else {
        result.append(lower..<upper)
      }
    }
    return result
  }

  /// Myers' O(ND) shortest edit script, deletions before insertions within
  /// a change.
  static func editScript(_ a: [Line], _ b: [Line]) -> [Step] {
    let n = a.count
    let m = b.count
    let maximum = n + m
    let offset = maximum + 1
    var v = Array(repeating: 0, count: 2 * maximum + 3)
    var trace: [[Int]] = []
    search: for d in 0...maximum {
      trace.append(v)
      for k in stride(from: -d, through: d, by: 2) {
        var x: Int
        if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
          x = v[offset + k + 1]
        } else {
          x = v[offset + k - 1] + 1
        }
        var y = x - k
        while x < n, y < m, a[x] == b[y] {
          x += 1
          y += 1
        }
        v[offset + k] = x
        if x >= n, y >= m { break search }
      }
    }
    var steps: [Step] = []
    var x = n
    var y = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
      let v = trace[d]
      let k = x - y
      let previousK: Int
      if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
        previousK = k + 1
      } else {
        previousK = k - 1
      }
      let previousX = v[offset + previousK]
      let previousY = previousX - previousK
      while x > previousX, y > previousY {
        x -= 1
        y -= 1
        steps.append(Step(kind: .equal, oldIndex: x, newIndex: y))
      }
      if d > 0 {
        if x == previousX {
          y -= 1
          steps.append(Step(kind: .insert, oldIndex: x, newIndex: y))
        } else {
          x -= 1
          steps.append(Step(kind: .delete, oldIndex: x, newIndex: y))
        }
      }
      x = previousX
      y = previousY
    }
    return steps.reversed()
  }
}
