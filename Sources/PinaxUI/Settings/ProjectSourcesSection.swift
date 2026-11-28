import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// Projects ▸ Sources: a row per thing Scan Now reads — a folder, its label
/// over its path and its include rule as a chip, or a command, its label over
/// the command and the folder it runs in — + / − under them with the last scan
/// and Scan Now, and under that group when the project is scanned unasked.
/// Clicking a row picks it for − and opens its fields under it. Every write
/// goes through the model, which writes `project.meta` through
/// `CatalogConfiguration`.
struct ProjectSourcesSection: View {
  let row: ProjectSettingsRow
  @ObservedObject var model: ProjectSettingsModel
  /// True while any scan or usage sync runs; Scan Now waits for it.
  let isScanning: Bool
  @State private var selectedLabel: String?

  static let addFolderTitle = "Add Folder…"
  static let addCommandTitle = "Add Command…"

  /// The command source Add Command… began in this project. While there is
  /// one it is the row picked.
  private var draft: ProjectSource? {
    model.commandDraft.flatMap { $0.project == row.slug ? $0.source : nil }
  }

  var body: some View {
    let draft = draft
    SettingsSection("Sources") {
      VStack(alignment: .leading, spacing: Metrics.sourceGroupSpacing) {
        SettingsGroup {
          ForEach(Array(row.sources.enumerated()), id: \.element.label) { index, source in
            if index > 0 { SettingsRowDivider() }
            let isSelected = draft == nil && source.label == selectedLabel
            SourceRowView(
              source: source,
              exists: ProjectSettingsModel.folderExists(source.directory),
              isSelected: isSelected,
              select: {
                model.discardCommandDraft()
                selectedLabel = isSelected ? nil : source.label
              },
              locate: { model.locateSource(label: source.label, inProject: row.slug) })
            if isSelected {
              SettingsRowDivider()
              editor(source)
            }
          }
          if let draft {
            if !row.sources.isEmpty { SettingsRowDivider() }
            SourceRowView(
              source: draft, exists: true, isSelected: true, select: {}, locate: {})
            SettingsRowDivider()
            CommandSourceEditor(
              source: draft, isNew: true, slug: row.slug, model: model,
              saved: { selectedLabel = $0 })
              .id("\(row.slug)|new")
          }
          if !row.sources.isEmpty || draft != nil { SettingsRowDivider() }
          SettingsAddRemoveBar(
            add: "Add source", remove: "Remove source",
            canRemove: draft != nil || selectedLabel != nil,
            addMenu: addMenu,
            onRemove: remove
          ) {
            HStack(spacing: Metrics.scanStatusSpacing) {
              Text(Self.scanLine(for: row, automatic: model.lastScanWasAutomatic(row)))
                .pinaxSettingsRowSubtitle()
                .help(ProjectSettingsModel.scanStatus(for: row))
              ScanNowButton(action: { model.scanNow?(row.slug) })
                .disabled(row.sources.isEmpty || isScanning)
            }
          }
        }
        ProjectAutomationGroup(row: row, model: model)
      }
    }
  }

  private var addMenu: [SettingsAddMenuItem] {
    [
      SettingsAddMenuItem(title: Self.addFolderTitle) { [model, slug = row.slug] in
        model.addSource(toProject: slug)
      },
      SettingsAddMenuItem(title: Self.addCommandTitle) { [model, slug = row.slug] in
        selectedLabel = nil
        model.beginCommandSource(inProject: slug)
      },
    ]
  }

  private func remove() {
    if draft != nil {
      model.discardCommandDraft()
    } else if let selectedLabel {
      model.removeSource(label: selectedLabel, fromProject: row.slug)
      self.selectedLabel = nil
    }
  }

  @ViewBuilder private func editor(_ source: ProjectSource) -> some View {
    switch source.kind {
    case .folder:
      SourceFieldsEditor(source: source) { label, include, exclude in
        model.updateSource(
          label: source.label, inProject: row.slug,
          newLabel: label, include: include, exclude: exclude)
        selectedLabel = label
      }
      .id("\(row.slug)|\(source.label)|\(source.include)|\(source.exclude)")
    case .command:
      CommandSourceEditor(
        source: source, isNew: false, slug: row.slug, model: model,
        saved: { selectedLabel = $0 })
        .id("\(row.slug)|\(source.label)|\(source.command)|\(source.workingDirectory)")
    }
  }

  /// The bar's words (`Scanned 2 weeks ago`, with `· automatic` when nobody
  /// asked for that scan); the count is the header's.
  static func scanLine(
    for row: ProjectSettingsRow, automatic: Bool = false, now: Date = Date(),
    locale: Locale = .current
  ) -> String {
    guard let lastScanAt = row.lastScanAt else { return "Never scanned" }
    let line = "Scanned \(PinaxFormat.relativeDate(lastScanAt, now: now, locale: locale))"
    return automatic ? line + " · automatic" : line
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

  /// A command row's second line before there is a command.
  static let noCommand = "No command"

  static func symbol(for kind: ProjectSource.Kind) -> String {
    kind == .command ? "terminal.fill" : "folder.fill"
  }

  /// A command row's trailing words: where the command runs.
  static func runsInText(_ source: ProjectSource) -> String {
    source.workingDirectory.isEmpty ? "" : "in \(shortPath(source.workingDirectory))"
  }

  /// The row's help: the path, or the whole command over its folder.
  static func help(for source: ProjectSource) -> String {
    switch source.kind {
    case .folder: return source.path
    case .command:
      return source.workingDirectory.isEmpty
        ? source.command : "\(source.command)\nin \(source.workingDirectory)"
    }
  }

  var body: some View {
    HStack(spacing: Metrics.rowSpacing) {
      Image(systemName: Self.symbol(for: source.kind))
        .resizable()
        .scaledToFit()
        .frame(width: Metrics.sourceFolderIconSize, height: Metrics.sourceFolderIconSize)
        .foregroundStyle(PinaxPalette.Settings.sourceFolder)
        .accessibilityHidden(true)
      // One line each: a path cut in the middle, a command at its end;
      // the whole of it is the help.
      VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
        Text(source.label)
          .lineLimit(1)
        secondLine
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(Self.help(for: source))
      SourcePathCell(source: source, exists: exists, locate: locate)
      switch source.kind {
      case .folder:
        SettingsCodeChip(source.effectiveInclude.joined(separator: ", "))
          .help(source.effectiveInclude.joined(separator: ", "))
      case .command:
        // Takes its width first, up to a limit, so the command gives way.
        CappedWidth(Metrics.sourceRunsInMaxWidth) {
          Text(verbatim: Self.runsInText(source))
            .pinaxSettingsRowSubtitle()
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .layoutPriority(1)
        .help(Self.help(for: source))
      }
    }
    .padding(.vertical, Metrics.rowVerticalPadding)
    .padding(.horizontal, Metrics.rowHorizontalPadding)
    .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
    .background(isSelected ? PinaxPalette.Settings.listSelection : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }

  @ViewBuilder private var secondLine: some View {
    switch source.kind {
    case .folder:
      Text(Self.shortPath(source.path))
        .pinaxSettingsRowSubtitle()
        .truncationMode(.middle)
    case .command:
      if source.command.isEmpty {
        // In the folder row's style, so a new command's row is as tall.
        Text(Self.noCommand)
          .pinaxSettingsRowSubtitle()
      } else {
        Text(verbatim: source.command)
          .pinaxSettingsChip()
          .foregroundStyle(.secondary)
          .truncationMode(.tail)
      }
    }
  }

  /// A path with `~` for home.
  static func shortPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }
}

/// Its one subview as wide as it asks to be, up to `limit`.
private struct CappedWidth: Layout {
  let limit: CGFloat

  init(_ limit: CGFloat) {
    self.limit = limit
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
  }

  private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
    ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height)
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
