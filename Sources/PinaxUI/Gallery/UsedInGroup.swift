import SwiftUI

/// The inspector's Used In group, after Projects: up to
/// five references, then Show All (N) — Usage ▸ Images as a table with this
/// image open. One selection only; more reads "—".
struct UsedInGroup: View {
  let state: UsedInState?
  let isMultiple: Bool
  /// In the library inspector's band — no title of its own, and
  /// each row a document glyph before a 12 pt line.
  var inBand = false
  /// The Usage page only: a row is the file's name over
  /// "project › directory", with the reference's line in a capsule.
  var showsReferenceDetail = false
  let showAll: () -> Void

  /// The rows as they read, for the tests.
  var rowTexts: [String] {
    guard !isMultiple, let state else { return ["—"] }
    switch state {
    case .unknown: return ["Unknown"]
    case .notUsed: return ["Not used"]
    case let .used(rows, _, _): return rows.map(\.text)
    }
  }

  /// The structured rows, for the Usage page's two-line form.
  var referenceRows: [UsedInRow] {
    guard !isMultiple, case let .used(rows, _, _) = state else { return [] }
    return rows
  }

  var showAllTitle: String? {
    guard !isMultiple, case let .used(rows, total, _) = state, total > rows.count else {
      return nil
    }
    return "Show All (\(total.formatted()))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
      if !inBand {
        Text("Used In")
          .pinaxSectionTitle()
      }
      if case .used = state, !isMultiple {
        if showsReferenceDetail {
          ForEach(Array(referenceRows.enumerated()), id: \.offset) { _, row in
            referenceRow(row)
          }
        } else {
          ForEach(rowTexts, id: \.self) { line in
            if inBand {
              HStack(spacing: DesignMetrics.inspectorUsedIn.spacing) {
                Image(systemName: "doc")
                  .pinaxGlyph(DesignMetrics.inspectorUsedIn.glyph)
                  .foregroundStyle(.secondary)
                Text(line)
                  .pinaxFieldValue()
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              .help(line)
            } else {
              Text(line)
                .pinaxBody()
                .lineLimit(1)
                .truncationMode(.middle)
                .help(line)
            }
          }
        }
      } else {
        Text(rowTexts.joined())
          .pinaxBody()
          .foregroundStyle(.tertiary)
      }
      if let showAllTitle {
        Button(showAllTitle, action: showAll)
          .buttonStyle(.link)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The Usage page's row: a document glyph, the file over
  /// "project › directory", the line in a capsule at the trailing end.
  private func referenceRow(_ row: UsedInRow) -> some View {
    HStack(spacing: DesignMetrics.inspectorUsedIn.spacing) {
      Image(systemName: "doc")
        .pinaxGlyph(DesignMetrics.inspectorUsedIn.glyph)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
        Text(row.fileName)
          .pinaxLinkName()
          .lineLimit(1)
          .truncationMode(.middle)
        Text(row.location)
          .pinaxLinkPath()
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if let line = row.line {
        UsageLineBadge(line: line)
      }
    }
    .help(row.text)
  }
}
