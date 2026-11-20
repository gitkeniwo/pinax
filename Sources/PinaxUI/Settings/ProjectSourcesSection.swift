import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// Projects ▸ Sources: a row per
/// folder Scan Now reads — the folder glyph, its label over its path, its
/// include rule as a chip — + / − under them with the last scan and Scan
/// Now. Clicking a row picks it for − and opens its fields under it. Every
/// write goes through the model, which writes `project.meta` through
/// `CatalogConfiguration`.
struct ProjectSourcesSection: View {
  let row: ProjectSettingsRow
  @ObservedObject var model: ProjectSettingsModel
  /// True while any scan or usage sync runs; Scan Now waits for it.
  let isScanning: Bool
  @State private var selectedLabel: String?

  var body: some View {
    SettingsSection("Sources") {
      SettingsGroup {
        ForEach(Array(row.sources.enumerated()), id: \.element.label) { index, source in
          if index > 0 { SettingsRowDivider() }
          SourceRowView(
            source: source,
            exists: ProjectSettingsModel.folderExists(source.path),
            isSelected: source.label == selectedLabel,
            select: { selectedLabel = selectedLabel == source.label ? nil : source.label },
            locate: { model.locateSource(label: source.label, inProject: row.slug) })
          if source.label == selectedLabel {
            SettingsRowDivider()
            SourceFieldsEditor(source: source) { label, include, exclude in
              model.updateSource(
                label: source.label, inProject: row.slug,
                newLabel: label, include: include, exclude: exclude)
              selectedLabel = label
            }
            .id("\(row.slug)|\(source.label)|\(source.include)|\(source.exclude)")
          }
        }
        if !row.sources.isEmpty { SettingsRowDivider() }
        SettingsAddRemoveBar(
          add: "Add source folder", remove: "Remove source folder",
          canRemove: selectedLabel != nil,
          onAdd: { model.addSource(toProject: row.slug) },
          onRemove: {
            guard let selectedLabel else { return }
            model.removeSource(label: selectedLabel, fromProject: row.slug)
            self.selectedLabel = nil
          }
        ) {
          HStack(spacing: Metrics.scanStatusSpacing) {
            Text(Self.scanLine(for: row))
              .pinaxSettingsRowSubtitle()
              .help(ProjectSettingsModel.scanStatus(for: row))
            ScanNowButton(action: { model.scanNow?(row.slug) })
              .disabled(row.sources.isEmpty || isScanning)
          }
        }
      }
    }
  }

  /// The bar's words (`Scanned 2 weeks ago`); the count is the header's.
  static func scanLine(for row: ProjectSettingsRow, now: Date = Date(), locale: Locale = .current)
    -> String
  {
    guard let lastScanAt = row.lastScanAt else { return "Never scanned" }
    return "Scanned \(PinaxFormat.relativeDate(lastScanAt, now: now, locale: locale))"
  }
}

/// One source's row. A folder that is not there (another machine, a moved
/// checkout) says so after its path, with Locate… to choose it again.
struct SourceRowView: View {
  let source: ProjectSource
  let exists: Bool
  let isSelected: Bool
  let select: () -> Void
  let locate: () -> Void

  var body: some View {
    HStack(spacing: Metrics.rowSpacing) {
      Image(systemName: "folder.fill")
        .resizable()
        .scaledToFit()
        .frame(width: Metrics.sourceFolderIconSize, height: Metrics.sourceFolderIconSize)
        .foregroundStyle(PinaxPalette.Settings.sourceFolder)
        .accessibilityHidden(true)
      // One line each, the path cut in the middle;
      // the full path is the help.
      VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
        Text(source.label)
          .lineLimit(1)
        Text(Self.shortPath(source.path))
          .pinaxSettingsRowSubtitle()
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(source.path)
      SourcePathCell(source: source, exists: exists, locate: locate)
      SettingsCodeChip(source.effectiveInclude.joined(separator: ", "))
        .help(source.effectiveInclude.joined(separator: ", "))
    }
    .padding(.vertical, Metrics.rowVerticalPadding)
    .padding(.horizontal, Metrics.rowHorizontalPadding)
    .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
    .background(isSelected ? PinaxPalette.Settings.listSelection : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }

  /// A path with `~` for home.
  static func shortPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }
}

/// A missing folder's mark in its row: the warning symbol, whose help says
/// so, and Locate…. A present folder draws nothing here.
struct SourcePathCell: View {
  let source: ProjectSource
  let exists: Bool
  let locate: () -> Void

  /// Locate… is drawn only for a folder that is not there.
  var showsLocate: Bool { !exists }

  var body: some View {
    if showsLocate {
      HStack(spacing: DesignMetrics.spacing.xs) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(PinaxPalette.StatusInk.warning)
          .help("Folder not found")
          .accessibilityLabel("Folder not found")
        Button("Locate…", action: locate)
          .controlSize(.small)
      }
    }
  }
}

/// The selected source's Label, Include and Exclude, in rows under it;
/// Include and Exclude are comma-separated. Return in any field, or Set,
/// commits all three.
private struct SourceFieldsEditor: View {
  let commit: (String, String, String) -> Void
  @State private var label: String
  @State private var include: String
  @State private var exclude: String
  private let stored: (String, String, String)

  init(source: ProjectSource, commit: @escaping (String, String, String) -> Void) {
    self.commit = commit
    let fields = (
      source.label, source.effectiveInclude.joined(separator: ", "),
      source.exclude.joined(separator: ", ")
    )
    stored = fields
    _label = State(initialValue: fields.0)
    _include = State(initialValue: fields.1)
    _exclude = State(initialValue: fields.2)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.sourceFieldSpacing) {
      field("Label", $label, prompt: nil)
      field("Include", $include, prompt: nil)
      field("Exclude", $exclude, prompt: "none")
      HStack {
        Spacer()
        Button("Set", action: apply)
          .disabled(label == stored.0 && include == stored.1 && exclude == stored.2)
      }
    }
    .padding(.vertical, Metrics.rowVerticalPadding)
    .padding(.horizontal, Metrics.rowHorizontalPadding)
  }

  private func field(_ title: String, _ text: Binding<String>, prompt: String?) -> some View {
    HStack(spacing: Metrics.rowSpacing) {
      Text(title)
        .pinaxSettingsValue()
        .frame(width: Metrics.sourceFieldLabelWidth, alignment: .leading)
      TextField(title, text: text, prompt: prompt.map { Text($0) })
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .onSubmit(apply)
    }
  }

  private func apply() {
    commit(label, include, exclude)
  }
}

/// Scan Now. Its action is the closure the app installs —
/// every entry point's button is this one, so tests can read which closure
/// each entry point carries.
struct ScanNowButton: View {
  let action: () -> Void
  /// The Usage header's form: the symbol, the words as its help.
  var iconOnly = false

  var body: some View {
    if iconOnly {
      Button(action: action) {
        Label("Scan Now", systemImage: "arrow.clockwise")
      }
      .labelStyle(.iconOnly)
      .help("Scan Now")
      .controlSize(.small)
    } else {
      Button("Scan Now", action: action)
        .controlSize(.small)
    }
  }
}

/// Add Source… and Open Project Settings… on the reports: opens the
/// Settings window, after `action` has turned it to Projects and selected
/// the project.
struct ProjectSettingsLinkButton: View {
  let title: String
  let action: () -> Void
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button(title) {
      action()
      openSettings()
    }
    .controlSize(.small)
  }
}

/// The empty-scan confirmation (Scan Now reuses the document import's
/// path) — shown by whichever window started the scan.
struct UsageEmptyScanConfirmation: ViewModifier {
  let model: UsageSyncModel?
  let presenter: UsageSyncPresenter

  func body(content: Content) -> some View {
    if let model {
      content.modifier(Presented(model: model, presenter: presenter))
    } else {
      content
    }
  }

  private struct Presented: ViewModifier {
    @ObservedObject var model: UsageSyncModel
    let presenter: UsageSyncPresenter

    func body(content: Content) -> some View {
      content.confirmationDialog(
        "Accept this empty usage scan?",
        isPresented: Binding(
          get: { model.isEmptyScanConfirmationPresented(by: presenter) },
          set: { shown in if !shown { model.cancelEmptyScan() } }),
        titleVisibility: .visible
      ) {
        Button("Accept Empty Scan", role: .destructive) {
          Task { await model.confirmEmptyScan() }
        }
        Button("Cancel", role: .cancel) { model.cancelEmptyScan() }
      } message: {
        Text(
          "This scan is empty. Accepting it will invalidate every existing reference for this project."
        )
      }
    }
  }
}

extension View {
  func usageEmptyScanConfirmation(_ model: UsageSyncModel?, presenter: UsageSyncPresenter)
    -> some View
  {
    modifier(UsageEmptyScanConfirmation(model: model, presenter: presenter))
  }
}
