import CatalogCore
import SwiftUI

/// The Externals context menu's buttons: several rows' "N Images" title,
/// Import into Catalog or Load Preview(s) with a divider under them,
/// the URL commands, a divider, then the file commands.
struct ExternalMenuButtons: View {
  @ObservedObject var model: ExternalsModel
  let items: [ExternalMenuItem]

  var body: some View {
    ForEach(items) { item in
      switch item {
      case .title:
        Text(item.title)
      case .openFile:
        Divider()
        button(item)
      default:
        button(item)
      }
      if Self.dividesAfter(item, in: items) {
        Divider()
      }
    }
  }

  /// The divider closing the leading commands: after the last of Import
  /// into Catalog, Load Preview(s) and Migrate to Bucket….
  static func dividesAfter(_ item: ExternalMenuItem, in items: [ExternalMenuItem]) -> Bool {
    let leading = items.filter {
      if case .importIntoCatalog = $0 { return true }
      if case .loadPreviews = $0 { return true }
      if case .migrateToBucket = $0 { return true }
      return false
    }
    return leading.last == item
  }

  @ViewBuilder
  private func button(_ item: ExternalMenuItem) -> some View {
    if let badge = item.badge {
      Button(item.title) { model.perform(item) }
        .badge(badge)
    } else {
      Button(item.title) { model.perform(item) }
        .disabled(!model.isEnabled(item))
    }
  }
}

/// The exception badge: the category's symbol,
/// white, on a filled circle of its colour.
struct ExternalImportBadge: View {
  let failure: ExternalImportFailure

  var body: some View {
    Image(systemName: failure.symbol)
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(.white)
      .imageScale(.small)
      .pinaxCaption()
      .bold()
      .frame(
        width: DesignMetrics.externals.badgeSize, height: DesignMetrics.externals.badgeSize
      )
      .background(ExternalsView.badgeColor(failure.category), in: Circle())
      .shadow(radius: DesignMetrics.externals.badgeShadowRadius)
      .help(failure.label)
      .accessibilityLabel(failure.label)
      .allowsHitTesting(false)
  }
}

/// An exception's words, or its symbol, in its colour: red for not found
/// (the error role), orange for a same image, secondary for the rest.
struct ExternalImportReason: View {
  let failure: ExternalImportFailure
  var text: String = ""
  var symbol = false

  var body: some View {
    Group {
      if symbol {
        Image(systemName: failure.symbol)
      } else {
        Text(text)
      }
    }
    .modifier(Tint(category: failure.category))
  }

  private struct Tint: ViewModifier {
    let category: ExternalImportFailure.Category

    func body(content: Content) -> some View {
      switch category {
      case .notFound:
        // Red first: the innermost foreground style wins over the caption's.
        content.pinaxError().pinaxCaption()
      case .sameImage:
        content.foregroundStyle(ExternalsView.badgeColor(.sameImage)).pinaxCaption()
      case .otherBackend, .skipped:
        content.pinaxCaption()
      }
    }
  }
}

/// The batch's mark on a cell: a spinner while its GET runs, ✓
/// once imported.
struct ExternalImportMark: View {
  let state: ExternalImportCellState?

  var body: some View {
    switch state {
    case .importing:
      ProgressView()
        .controlSize(.small)
        .padding(DesignMetrics.spacing.xs)
        .background(.regularMaterial, in: Circle())
    case .imported:
      Image(systemName: ExternalsView.importedSymbol)
        .symbolRenderingMode(.multicolor)
        .imageScale(.large)
    case nil:
      EmptyView()
    }
  }
}

/// The result bar under the header: what the batch did, closable;
/// Show in Usage once something was imported. Archived's banner's form.
struct ExternalImportSummaryBar: View {
  @ObservedObject var model: ExternalsModel
  let summary: ExternalImportSummary

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.m) {
      Image(systemName: ExternalsView.importedSymbol)
        .symbolRenderingMode(.multicolor)
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
        Text(summary.title)
          .pinaxSectionTitle()
          .foregroundStyle(.primary)
          .monospacedDigit()
        if let detail = summary.detail {
          Text(detail)
            .pinaxSecondary()
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: DesignMetrics.spacing.m)
      if summary.offersUsage {
        Button("Show in Usage") { model.showImportedInUsage() }
          .buttonStyle(.link)
      }
      Button {
        model.dismissImportSummary()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Close")
    }
    .controlSize(.small)
    .padding(.horizontal, ChromeMetrics.horizontalPadding)
    .padding(.vertical, DesignMetrics.spacing.s)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
}

/// The import sheet, in Delete Permanently…'s layout — title,
/// one sentence, the facts, a note, the fine print, the buttons. Import
/// holds Return: it writes catalog rows only and nothing remote, and
/// Remove takes an image back out — unlike the permanent delete, where
/// Return cancels.
struct ExternalImportSheetView: View {
  @ObservedObject var model: ExternalsModel
  let sheet: ExternalImportSheet

  /// While the CDN check runs (one or two seconds): neither button, nor Esc.
  private var isChecking: Bool {
    if case .confirm(_, checking: true) = sheet { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      switch sheet {
      case let .confirm(confirmation, checking):
        confirm(confirmation, checking: checking)
      case let .refused(refusal):
        refused(refusal)
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: DesignMetrics.backupSheet.width)
    .interactiveDismissDisabled(isChecking)
    .onExitCommand { model.cancelImportSheet() }
  }

  @ViewBuilder
  private func confirm(_ confirmation: ExternalImportConfirmation, checking: Bool) -> some View {
    Text(confirmation.title)
      .pinaxTitle()
    Text(confirmation.subtitle)
      .pinaxSecondary()
      .fixedSize(horizontal: false, vertical: true)
    facts(confirmation.lines)
    if checking {
      HStack(spacing: DesignMetrics.spacing.s) {
        ProgressView()
          .controlSize(.small)
        Text(confirmation.checkingText)
          .pinaxSecondary()
      }
    } else if let warning = confirmation.cdnWarning {
      note(warning)
    }
    Text(confirmation.finePrint)
      .pinaxSecondary()
      .fixedSize(horizontal: false, vertical: true)
    HStack {
      Spacer()
      Button("Cancel") { model.cancelImportSheet() }
        .keyboardShortcut(.cancelAction)
      Button("Import") { Task { await model.confirmImport() } }
        .keyboardShortcut(.defaultAction)
    }
    .disabled(checking)
  }

  @ViewBuilder
  private func refused(_ refusal: ExternalImportRefusal) -> some View {
    Text(refusal.title)
      .pinaxTitle()
    Text(refusal.subtitle)
      .pinaxSecondary()
      .fixedSize(horizontal: false, vertical: true)
    facts(refusal.lines)
    note(refusal.advice)
    HStack {
      Spacer()
      Button("OK") { model.cancelImportSheet() }
        .keyboardShortcut(.defaultAction)
    }
  }

  private func facts(_ lines: [ExternalImportConfirmation.Line]) -> some View {
    Form {
      Section {
        ForEach(lines, id: \.label) { line in
          LabeledContent(line.label) {
            Text(line.value)
              .monospacedDigit()
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func note(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
      Image(systemName: "exclamationmark.triangle.fill")
        .symbolRenderingMode(.multicolor)
      Text(text)
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// The status bar's left side on Externals: the selection's
/// count, hosts and files — its own view, so the bar redraws on the
/// page's selection.
struct ExternalSelectionStatus: View {
  @ObservedObject var model: ExternalsModel

  var body: some View {
    if let text = model.selectionStatusText {
      ChromeMetrics.text(text)
    }
  }
}
