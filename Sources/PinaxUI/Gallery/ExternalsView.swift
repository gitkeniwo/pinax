import CatalogCore
import SwiftUI

/// A read-only catalog report beside Orphans. It deliberately has its own
/// model and row shape: external URLs are usage facts, not orphaned assets.
///
/// The report's title row is a scope bar — Your domains (N) | Other
/// domains (N) with the counts in capsules, the page's import entry and ⓘ,
/// and the soft lock capsule. Its scope is the current project. Each
/// half shows as a grid or a table, the toolbar's Grid | Table; both draw the model's one grouping and one selection.
struct ExternalsView: View {
  @ObservedObject var model: ExternalsModel
  /// The library's column count, which the toolbar's slider and ⌘+ / ⌘−
  /// move; `zoom` moves it a rung (+1 bigger) for a pinch.
  var columns = GridZoom.defaultColumns
  var zoom: (Int) -> Void = { _ in }
  /// The table's width, for dropping Used In when it is narrow.
  @State private var tableWidth: CGFloat = 0

  /// Below this the table drops its Used In column (header and rows),
  /// so Host, Kind and Refs keep fitting; 0 (not measured yet) keeps it.
  static let usedInMinimumWidth: CGFloat = 460

  static func showsUsedIn(tableWidth: CGFloat) -> Bool {
    tableWidth == 0 || tableWidth >= usedInMinimumWidth
  }

  /// Size goes before Used In — below the width Used In
  /// needs plus Size's own column and its gap. With Size gone, Used In's
  /// threshold is unchanged.
  static let sizeMinimumWidth: CGFloat =
    usedInMinimumWidth + DesignMetrics.externalsTable.sizeWidth + DesignMetrics.externalsTable.childSpacing

  static func showsSize(tableWidth: CGFloat) -> Bool {
    tableWidth == 0 || tableWidth >= sizeMinimumWidth
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The title row is a scope bar — the two
      // halves with their counts, then the page's own import entry and the
      // soft lock capsule.
      ExternalScopeBar(model: model)
      // The first-visit card: once, until its ✕.
      if model.showsTip {
        ExternalsTipBar(model: model)
      }
      if let summary = model.importSummary {
        ExternalImportSummaryBar(model: model, summary: summary)
      }
      Group {
        if case let .error(loadError) = model.presentation {
          FailureStateView(message: loadError)
        } else if case let .results(rows) = model.presentation {
          if rows.isEmpty {
            emptyState
          } else {
            switch model.viewMode {
            case .grid: ExternalsGrid(model: model, columns: columns, zoom: zoom)
            case .table:
              VStack(spacing: DesignMetrics.spacing.none) {
                ExternalsListHeader(model: model)
                ExternalsList(model: model, selection: $model.selection)
              }
              .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
              .environment(\.externalsShowsUsedIn, Self.showsUsedIn(tableWidth: tableWidth))
              .environment(\.externalsShowsSize, Self.showsSize(tableWidth: tableWidth))
            }
          }
        } else if model.presentation == .empty {
          emptyState
        } else {
          ProgressView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // The migration's confirmation, on the window.
    .sheet(
      isPresented: Binding(
        get: { model.isMigrationSheetPresented && model.migrationConfirmation != nil },
        set: { if !$0 { model.dismissMigrationSheet() } })
    ) {
      if let confirmation = model.migrationConfirmation {
        ExternalMigrationSheet(model: model, confirmation: confirmation)
      }
    }
    // The import's confirmation, its CDN check and its refusal.
    .sheet(
      isPresented: Binding(
        get: { model.importSheet != nil },
        set: { if !$0 { model.cancelImportSheet() } })
    ) {
      if let sheet = model.importSheet {
        ExternalImportSheetView(model: model, sheet: sheet)
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView(.noExternalReferences)
  }

  // MARK: - Shared by both views and the inspector

  /// Every symbol the views draw; a test checks each exists.
  static let symbols =
    [placeholderSymbol, failedSymbol, privacySymbol, copySymbol, importedSymbol, stopSymbol,
     ExternalsInfoButton.symbol, ExternalsTipBar.symbol, fileSymbol, openURLSymbol,
     loadPreviewSymbol, stopLoadingSymbol, groupSymbol, selectionSymbol, migrateSymbol, "chevron.up",
     "chevron.down"]
    + ExternalImportFailure.Category.allCases.map(ExternalImportFailure.symbol)
  static let placeholderSymbol = "photo"
  static let failedSymbol = "photo.badge.exclamationmark"
  static let privacySymbol = "lock"
  static let copySymbol = "doc.on.doc"
  /// A tile the batch has imported, and the status bar's
  /// stop button.
  static let importedSymbol = "checkmark.circle.fill"
  static let stopSymbol = "stop.circle.fill"
  /// A Group by File group's mark in the list, where a host has its
  /// letter.
  static let fileSymbol = "doc.text"
  /// The inspector's Link band's Open URL button and its Load preview.
  static let openURLSymbol = "arrow.up.right.square"
  /// Every Load, the capsule's mark (filled).
  static let loadPreviewSymbol = "eye.fill"
  /// The status bar's Stop loading, grey.
  static let stopLoadingSymbol = "xmark.circle.fill"
  /// The jump bar's Group pop-up.
  static let groupSymbol = "rectangle.grid.1x2.fill"
  /// Several rows' inspector title.
  static let selectionSymbol = "photo.stack.fill"
  /// Every Migrate entry (filled).
  static let migrateSymbol = "arrow.up.circle.fill"

  /// The exception badge's fill: red for not found,
  /// orange for a same image, grey for the rest — each with its own shape.
  static func badgeColor(_ category: ExternalImportFailure.Category) -> Color {
    switch category {
    case .notFound: Color(nsColor: .systemRed)
    case .sameImage: Color(nsColor: .systemOrange)
    case .otherBackend, .skipped: Color(nsColor: .systemGray)
    }
  }

  /// The URL's last path component, or the URL when it has none.
  static func filename(_ row: ExternalReference) -> String {
    let name = URL(string: row.rawURL)?.lastPathComponent ?? ""
    return name.isEmpty || name == "/" ? row.rawURL : name
  }

  /// The host-less directory path (`wiki/en/e/e9`): the child row's second
  /// line.
  static func directoryPath(_ row: ExternalReference) -> String {
    guard let url = URL(string: row.rawURL) else { return "" }
    let parts = url.pathComponents.filter { $0 != "/" }
    return parts.dropLast().joined(separator: "/")
  }

  /// The Link band's second line: "host › directory › …".
  static func linkLocation(_ row: ExternalReference) -> String {
    guard let url = URL(string: row.rawURL), let host = url.host else { return row.rawURL }
    let parts = url.pathComponents.filter { $0 != "/" }
    let directory = parts.dropLast().joined(separator: " › ")
    return directory.isEmpty ? host : "\(host) › \(directory)"
  }

  /// The referencing file's name, without its directories.
  static func sourceFile(_ row: ExternalReference) -> String {
    (UsageReferenceRow.split(row.sourceReference).file as NSString).lastPathComponent
  }

  /// The referencing file's directory, under its project.
  static func sourceDirectory(_ row: ExternalReference, showsProject: Bool) -> String {
    let file = UsageReferenceRow.split(row.sourceReference).file
    let directory = (file as NSString).deletingLastPathComponent
    let tail = directory.isEmpty ? (file as NSString).deletingPathExtension : directory
    return showsProject ? "\(row.projectSlug) › \(tail)" : tail
  }

  /// The line number the source reference carries (`#L18`), nil if none.
  static func line(_ row: ExternalReference) -> Int? {
    UsageReferenceRow.split(row.sourceReference).line
  }

  /// The Kind column's mark: MD for markdown, else the kind's short
  /// capitals (a 9.5 pt mark).
  static func kindMark(_ kind: String) -> String {
    switch kind.lowercased() {
    case "markdown", "md", "mdx": return "MD"
    case "html", "htm": return "HTML"
    default: return String(kind.uppercased().prefix(4))
    }
  }

  /// The preview/source square's MIME from the URL's extension, so
  /// `FormatSquare` can use the one format-to-hue table.
  static func mime(_ row: ExternalReference) -> String {
    switch (URL(string: row.rawURL)?.pathExtension ?? "").lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case let ext where !ext.isEmpty: return "image/\(ext)"
    default: return ""
    }
  }

  /// The title bar's second line: where the reference stands, then the
  /// host.
  static func headerSubtitle(_ row: ExternalReference, failure: ExternalImportFailure?) -> String {
    let rawHost = URL(string: row.rawURL)?.host ?? ""
    let domain = rawHost.isEmpty ? "" : ExternalHostRow.hostParts(rawHost).base
    let standing = ExternalInspector.subtitle(row, failure: failure)
    return domain.isEmpty ? standing : "\(standing) · \(domain)"
  }

  /// "a · L11": the referencing file's name and the line.
  static func place(_ row: ExternalReference) -> String {
    let split = UsageReferenceRow.split(row.sourceReference)
    let name = (split.file as NSString).lastPathComponent
    let stem = (name as NSString).deletingPathExtension
    let title = stem.isEmpty ? name : stem
    return split.line.map { "\(title) · L\($0)" } ?? title
  }

  /// "L11" alone under Group by File, whose header names the file; else
  /// `place`.
  static func place(_ row: ExternalReference, inFileGroup: Bool) -> String {
    guard inFileGroup else { return place(row) }
    return UsageReferenceRow.split(row.sourceReference).line.map { "L\($0)" } ?? place(row)
  }

  /// "PNG", from the URL's extension.
  /// The tile's corner: "412 KB · JPEG" once loaded, as the library's
  /// before that the URL's extension.
  static func cornerLabel(_ row: ExternalReference, state: ExternalThumbnail?) -> String? {
    if case let .loaded(_, info?)? = state {
      return "\(PinaxFormat.fileSize(info.bytes)) · \(info.typeName)"
    }
    return format(row)
  }

  static func format(_ row: ExternalReference) -> String? {
    let ext = URL(string: row.rawURL)?.pathExtension ?? ""
    return ext.isEmpty ? nil : ext.uppercased()
  }

  /// The context menu's rows: the selection when the clicked row is in
  /// it, else the clicked row (Finder's rule, as the table's was).
  static func menuIDs(_ row: ExternalReference, selection: Set<ExternalReference.ID>)
    -> Set<ExternalReference.ID>
  {
    selection.contains(row.id) ? selection : [row.id]
  }
}

/// The Externals page's scope bar: Your
/// domains (N) | Other domains (N) in one segmented capsule, then the
/// page's import entry and ⓘ, and — on Other Domains — the soft lock
/// capsule.
struct ExternalScopeBar: View {
  @ObservedObject var model: ExternalsModel

  /// The segment's words: "Your domains" / "Other domains";
  /// "Yours" / "Other" when the column is too narrow for them.
  static func title(_ domain: ExternalDomain, short: Bool = false) -> String {
    switch domain {
    case .yours: return short ? "Yours" : "Your domains"
    case .other: return short ? "Other" : "Other domains"
    }
  }

  /// The bar never outgrows the centre column. The widest layout that
  /// fits wins: the capsule gives way first (sentence → eye and Load All →
  /// Load All), then the segments take their short titles.
  var body: some View {
    ViewThatFits(in: .horizontal) {
      bar(short: false, capsule: .full)
      bar(short: false, capsule: .icon)
      bar(short: false, capsule: .bare)
      bar(short: true, capsule: .icon)
      bar(short: true, capsule: .bare)
    }
    .padding(.horizontal, DesignMetrics.externalsTable.scopeHorizontalPadding)
    .frame(maxWidth: .infinity)
    .frame(height: DesignMetrics.externalsTable.scopeHeight)
    .background(PinaxPalette.scope)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func bar(short: Bool, capsule style: ExternalPreviewCapsuleView.Style) -> some View {
    HStack(spacing: DesignMetrics.externalsTable.scopeSpacing) {
      HStack(spacing: DesignMetrics.spacing.none) {
        segment(.yours, short: short)
        segment(.other, short: short)
      }
      .padding(DesignMetrics.externalsTable.segmentPadding)
      .background(
        PinaxPalette.grp,
        in: RoundedRectangle(
          cornerRadius: DesignMetrics.externalsTable.segmentGroupRadius, style: .continuous))

      Spacer(minLength: DesignMetrics.externalsTable.scopeSpacing)

      if model.showsImportAll {
        Button("Import All…") { Task { await model.requestImportAll() } }
          .controlSize(.small)
          .disabled(!model.isImportAllEnabled)
      }
      if model.items != nil {
        ExternalsInfoButton(model: model)
      }
      if let capsule = model.previewCapsule {
        ExternalPreviewCapsuleView(model: model, capsule: capsule, style: style)
      }
    }
  }

  private func segment(_ domain: ExternalDomain, short: Bool) -> some View {
    let isSelected = model.domain == domain
    return Button {
      guard !isSelected else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { model.domain = domain }
    } label: {
      HStack(spacing: DesignMetrics.externalsTable.segmentSpacing) {
        Text(Self.title(domain, short: short))
          .pinaxScopeSegment()
          .fontWeight(isSelected ? .medium : .regular)
          .lineLimit(1)
          .fixedSize()
        // The count as a plain tabular number, a step quieter than the
        // name (no capsule nested in the segment's own plate).
        Text(model.count(domain).formatted())
          .pinaxCount()
          .monospacedDigit()
          .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
          .lineLimit(1)
          .fixedSize()
      }
      .foregroundStyle(
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .padding(.horizontal, DesignMetrics.externalsTable.segmentHorizontalPadding)
      .padding(.vertical, DesignMetrics.externalsTable.segmentVerticalPadding)
      .background {
        if isSelected {
          RoundedRectangle(
            cornerRadius: DesignMetrics.externalsTable.segmentRadius, style: .continuous
          )
          .fill(PinaxPalette.segment)
          .shadow(
            color: .black.opacity(DesignMetrics.externalsTable.segmentShadowOpacity),
            radius: DesignMetrics.externalsTable.segmentShadowRadius, y: 1)
          .overlay {
            RoundedRectangle(
              cornerRadius: DesignMetrics.externalsTable.segmentRadius, style: .continuous
            )
            .strokeBorder(
              .black.opacity(DesignMetrics.externalsTable.segmentShadowOpacity),
              lineWidth: DesignMetrics.externalsTable.segmentHairline)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A remote thumbnail or its placeholder: Your Domains' image, why it is
/// missing, or — Other Domains — a dashed frame that loads nothing.
struct ExternalThumbnailView: View {
  let state: ExternalThumbnail?
  var showsReason = true
  var contentMode = ContentMode.fill
  /// The table's selected row: the dashed frame and its glyph turn white
  /// on the accentFill plate.
  var isSelected = false

  var body: some View {
    ZStack {
      switch state {
      case .loaded(let image, _):
        // An overlay on clear, as the grid cell's image is: the frame is
        // the one it is given, never the image's — a wide image filling
        // its tile no longer widens the tile, nor the inspector's column.
        Color.clear
          .overlay {
            Image(decorative: image, scale: 1)
              .resizable()
              .aspectRatio(contentMode: contentMode)
          }
          .clipped()
      case .failed(let reason):
        VStack(spacing: DesignMetrics.spacing.xs) {
          Image(systemName: ExternalsView.failedSymbol)
            .imageScale(.large)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
          if showsReason {
            Text(reason)
              .pinaxCaption()
              .lineLimit(2)
              .multilineTextAlignment(.center)
          }
        }
        .padding(DesignMetrics.spacing.xs)
        .help(reason)
      case .loading:
        Image(systemName: ExternalsView.placeholderSymbol)
          .imageScale(.large)
          .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
      case nil:
        RoundedRectangle(cornerRadius: DesignMetrics.externalsTable.thumbnailRadius)
          .fill(isSelected ? Color.white.opacity(0.10) : PinaxPalette.band)
          .overlay {
            RoundedRectangle(cornerRadius: DesignMetrics.externalsTable.thumbnailRadius)
              .strokeBorder(
                isSelected ? AnyShapeStyle(.white.opacity(0.55)) : AnyShapeStyle(.tertiary),
                style: StrokeStyle(
                  lineWidth: DesignMetrics.externalsTable.placeholderStroke,
                  dash: [DesignMetrics.externalsTable.placeholderDash]))
          }
        Image(systemName: ExternalsView.placeholderSymbol)
          .imageScale(.medium)
          .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Board A: Grid

/// Board A: a section per domain, tiles under it — the library grid's
/// mechanics (`AssetGridView`): its fixed column count, so the toolbar's
/// slider, ⌘+ / ⌘− and a pinch zoom it; its spacing and inset; its pinned
/// section headers. A tap is the library's (`ExternalsModel.clickCell`);
/// a click between tiles clears.
struct ExternalsGrid: View {
  @ObservedObject var model: ExternalsModel
  var columns = GridZoom.defaultColumns
  var zoom: (Int) -> Void = { _ in }

  @State private var pinchAccumulator = PinchZoomAccumulator()
  @State private var pinchPreviousScale: CGFloat?

  /// The library grid's: `columns` equal flexible columns.
  static func gridItems(columns: Int) -> [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: AssetGridView.cellSpacing, alignment: .top),
      count: columns)
  }

  /// Pinned, as the library's month headers are: the domain stays on top
  /// while its tiles scroll under it.
  static let pinnedViews: PinnedScrollableViews = [.sectionHeaders]

  /// One domain: its header in the `Section` header slot — that slot is what
  /// pins it while the tiles scroll under (`pinnedViews` only pins headers).
  func section(_ group: ExternalGroup) -> some View {
    Section {
      LazyVGrid(columns: Self.gridItems(columns: columns), spacing: AssetGridView.rowSpacing) {
        ForEach(group.rows) { row in
          ExternalTile(
            row: row, state: model.thumbnail(row),
            isSelected: model.selection.contains(row.id),
            importState: model.importCellState(row), failure: model.importFailure(row),
            inFileGroup: group.isFile
          )
          .contentShape(Rectangle())
          .onTapGesture { model.clickCell(row) }
          .onAppear { model.loadThumbnail(row) }
          .contextMenu {
            ExternalMenuButtons(
              model: model,
              items: model.menuItems(for: ExternalsView.menuIDs(row, selection: model.selection)))
          }
        }
      }
    } header: {
      ExternalGroupHeader(
        group: group, preview: model.groupPreview(group),
        loadPreviews: { model.loadPreviews(group.rows) },
        migrateCount: model.migrationURLs(group.rows).count, isMigrationBusy: model.isMigrationBusy,
        migrate: { Task { await model.migrate(group.rows) } })
    }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: AssetGridView.rowSpacing, pinnedViews: Self.pinnedViews) {
        ForEach(model.groups) { group in
          section(group)
        }
      }
      .padding(AssetGridView.gridInset / 2)
    }
    .contentShape(Rectangle())
    .onTapGesture { model.selection = [] }
    .onCommand(#selector(NSText.copy(_:))) {
      model.copySelection()
    }
    .coordinateSpace(name: AssetGridView.scrollSpace)
    .simultaneousGesture(
      MagnifyGesture()
        .onChanged { value in pinch(scale: value.magnification) }
        .onEnded { _ in
          pinchPreviousScale = nil
          pinchAccumulator.reset()
        }
    )
  }

  /// The library grid's pinch (`AssetGridView`): rungs out of the
  /// accumulator, each one `zoom`'s step.
  private func pinch(scale: CGFloat) {
    defer { pinchPreviousScale = scale }
    guard let previous = pinchPreviousScale else { return }
    var rungs = pinchAccumulator.advance(by: scale - previous)
    while rungs != 0 {
      zoom(rungs > 0 ? 1 : -1)
      rungs += rungs > 0 ? -1 : 1
    }
  }
}

/// A Grid section's title: the host in bold, then "current domain of r2 ·
/// 3"; pinned, it gains the library's bar plate.
struct ExternalGroupHeader: View {
  let group: ExternalGroup
  /// Load N on hover, or ✓ Previews.
  var preview: ExternalGroupPreview = .none
  var loadPreviews: () -> Void = {}
  /// Migrate N… beside Load N.
  var migrateCount = 0
  var isMigrationBusy = false
  var migrate: () -> Void = {}
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      ExternalDomainSquare(host: group.host, isFile: group.isFile)
      Text(group.host)
        .pinaxBody()
        .bold()
        .lineLimit(1)
      Text(group.note)
        .pinaxSecondary()
        .monospacedDigit()
        .lineLimit(1)
      Spacer(minLength: DesignMetrics.spacing.s)
      ExternalGroupPreviewControl(preview: preview, isHovering: isHovering, load: loadPreviews)
      ExternalGroupMigrateControl(
        count: migrateCount, isHovering: isHovering, isBusy: isMigrationBusy, migrate: migrate)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .pinnedSectionPlate()
  }
}

/// A group header's preview control: a borderless accent
/// "Load N" while the pointer is over the header; a quiet ✓ Previews once
/// every URL is loaded.
struct ExternalGroupPreviewControl: View {
  let preview: ExternalGroupPreview
  let isHovering: Bool
  let load: () -> Void

  var body: some View {
    switch preview {
    case let .load(count) where isHovering:
      Button(action: load) {
        Label("Load \(count.formatted())", systemImage: ExternalsView.loadPreviewSymbol)
          .labelStyle(.titleAndIcon)
          .fontWeight(.semibold)
          .lineLimit(1)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(PinaxPalette.accent)
      .controlSize(.small)
      .fixedSize()
    case .loaded:
      Label("Previews", systemImage: ExternalsView.importedSymbol)
        .labelStyle(.titleAndIcon)
        .pinaxCaption()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    default:
      EmptyView()
    }
  }
}

/// The Other Domains capsule: "N of M previews loaded" with an
/// inline Load All; "All M previews loaded" alone once they are.
struct ExternalPreviewCapsuleView: View {
  @ObservedObject var model: ExternalsModel
  let capsule: ExternalPreviewCapsule
  /// How much of it the scope bar has room for.
  var style: Style = .full

  enum Style {
    /// The eye, the sentence and Load All.
    case full
    /// The eye and Load All.
    case icon
    /// Load All alone (the eye alone once all are loaded).
    case bare
  }

  var body: some View {
    pill(showsText: style == .full, showsIcon: style != .bare || !capsule.showsLoadAll)
      .help(
        style == .full
          ? "Previews load from other hosts only when you choose Load."
          : "\(capsule.text). Previews load from other hosts only when you choose Load.")
  }

  // The message in secondary text, Load All its own small
  // accent-filled capsule inside.
  private func pill(showsText: Bool, showsIcon: Bool) -> some View {
    HStack(spacing: DesignMetrics.spacing.xs) {
      if showsIcon {
        Image(systemName: ExternalsView.loadPreviewSymbol)
      }
      if showsText {
        Text(capsule.text)
          .monospacedDigit()
          .lineLimit(1)
      }
      if capsule.showsLoadAll {
        Button {
          if case let .results(rows) = model.presentation { model.loadPreviews(rows) }
        } label: {
          Text("Load All")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(PinaxPalette.accentFill, in: Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .pinaxCapsuleLabel()
    .foregroundStyle(.secondary)
    .padding(.leading, showsIcon || showsText ? DesignMetrics.soft.capsuleHorizontalPadding : 3)
    .padding(.trailing, capsule.showsLoadAll ? 3 : DesignMetrics.soft.capsuleHorizontalPadding)
    .frame(height: DesignMetrics.soft.capsuleHeight)
    .background(PinaxPalette.soft, in: Capsule())
    .fixedSize()
  }
}

/// A domain's letter square (`PinaxPalette.domainToken`), or Group by File's
/// grey document: the table's domain row, the Grid's section titles and the
/// inspector's Link row all show the same one.
struct ExternalDomainSquare: View {
  let host: String
  var isFile = false

  var body: some View {
    if isFile {
      ColorSquare(
        size: .sidebar, color: PinaxPalette.color(.gray),
        content: .symbol(ExternalsView.fileSymbol))
    } else {
      ColorSquare(
        size: .sidebar, color: PinaxPalette.color(PinaxPalette.domainToken(host)),
        content: .letters(ExternalHostRow.avatarLetter(host)))
    }
  }
}

/// The grid's tile: the image (or why not) with its format in the library's
/// corner label, the file name and where it is used under it. No "Not in
/// catalog" — the half says it — and a badge only for an exception, whose
/// reason replaces the second line. While a batch runs, a spinner, then ✓
/// and dimmed.
struct ExternalTile: View {
  let row: ExternalReference
  let state: ExternalThumbnail?
  let isSelected: Bool
  var importState: ExternalImportCellState?
  var failure: ExternalImportFailure?
  var inFileGroup = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.grid.captionSpacing) {
      // The cell's frame: a fixed-aspect plate the image is laid over.
      RoundedRectangle(cornerRadius: DesignMetrics.radius.thumbnail)
        .fill(.quaternary)
        .aspectRatio(DesignMetrics.externals.tileAspectRatio, contentMode: .fit)
        .overlay { ExternalThumbnailView(state: state) }
        .overlay(alignment: .bottomTrailing) {
          if let format = ExternalsView.cornerLabel(row, state: state) {
            Text(format)
              .gridCornerLabel(weight: .semibold)
              .padding(DesignMetrics.externals.badgeInset)
              .allowsHitTesting(false)
          }
        }
        .overlay(alignment: .topTrailing) {
          if let failure {
            ExternalImportBadge(failure: failure)
              .padding(DesignMetrics.externals.badgeInset)
          }
        }
        .overlay { ExternalImportMark(state: importState) }
        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radius.thumbnail))
        .overlay {
          if isSelected {
            RoundedRectangle(cornerRadius: DesignMetrics.selection.ringRadius)
              .strokeBorder(PinaxPalette.accent, lineWidth: DesignMetrics.selection.ringWidth)
              .padding(-(DesignMetrics.selection.ringGap + DesignMetrics.selection.ringWidth))
              .allowsHitTesting(false)
          }
        }
      Text(ExternalsView.filename(row))
        .foregroundStyle(.primary)
        .pinaxCaption()
        .lineLimit(1)
        .truncationMode(.middle)
        .help(row.rawURL)
      if let failure {
        ExternalImportReason(failure: failure, text: failure.caption)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(failure.explanation)
      } else {
        Text(ExternalsView.place(row, inFileGroup: inFileGroup))
          .pinaxCaption()
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .opacity(importState == .imported ? DesignMetrics.externals.importedOpacity : 1)
  }
}

// MARK: - Board B: grouped list

/// The table: the domains as flat rows — no disclosure
/// chevron: a domain's square opens and closes its references, the rest of
/// the row leaves the selection alone. Only the first domain is open until
/// the user says otherwise. The context menu, double-click and ⌘C are
/// the rows' own.
struct ExternalsList: View {
  @ObservedObject var model: ExternalsModel
  @Binding var selection: Set<ExternalReference.ID>

  var body: some View {
    List(selection: $selection) {
      ForEach(model.groups) { group in
        let expanded = model.isExpanded(group)
        ExternalHostRow(
          group: group, isExpanded: expanded, preview: model.groupPreview(group),
          loadPreviews: { model.loadPreviews(group.rows) },
          migrateCount: model.migrationURLs(group.rows).count, isMigrationBusy: model.isMigrationBusy,
          migrate: { Task { await model.migrate(group.rows) } }
        ) {
          toggle(group, expanded: expanded)
        }
        .selectionDisabled()
        .listRowInsets(Self.rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        if expanded {
          ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
            ExternalListRow(
              row: row, state: model.thumbnail(row), isSelected: selection.contains(row.id),
              importState: model.importCellState(row), failure: model.importFailure(row),
              inFileGroup: group.isFile, childIndex: index, childCount: group.rows.count
            )
            .tag(row.id)
            .onAppear { model.loadThumbnail(row) }
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(
              ExternalSelectionPlate(isSelected: selection.contains(row.id)))
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(PinaxPalette.windowGround)
    .environment(\.defaultMinListRowHeight, 1)
    // AppKit's blue highlight and inset row padding off: the plate and the
    // 8 + 8 insets are the rows' own.
    .background(ListHighlightOff(selectionCount: selection.count))
    .contextMenu(forSelectionType: ExternalReference.ID.self) { ids in
      ExternalMenuButtons(model: model, items: model.menuItems(for: ids))
    } primaryAction: { ids in
      open(ids)
    }
    .onCommand(#selector(NSText.copy(_:))) {
      model.copySelection()
    }
  }

  /// The rows sit in a container padded 4 × 8: the outline's
  /// row is inset 8, and the row itself then pads another 8.
  static let rowInsets = EdgeInsets(
    top: 0, leading: DesignMetrics.externalsTable.selectionInset, bottom: 0,
    trailing: DesignMetrics.externalsTable.selectionInset)

  /// The square's click: opening and closing is immediate, with no
  /// animation, and never changes the selection.
  private func toggle(_ group: ExternalGroup, expanded: Bool) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { model.setExpanded(group, !expanded) }
  }

  /// Double-click.
  var open: (Set<ExternalReference.ID>) -> Void { model.openPrimary }
}

/// The selected reference row's plate (corner 7,
/// accentFill). The row is already inset from the table's edges.
struct ExternalSelectionPlate: View {
  let isSelected: Bool

  var body: some View {
    if isSelected {
      RoundedRectangle(
        cornerRadius: DesignMetrics.externalsTable.selectionRadius, style: .continuous
      )
      .fill(PinaxPalette.accentFill)
      .padding(.horizontal, DesignMetrics.externalsTable.selectionInset)
    }
  }
}

/// A domain row: its letter square (stacked when
/// closed), the subdomain in grey over the bold base domain, and the 34 pt
/// count capsule in the Refs column. The square toggles the group; the row
/// never selects.
struct ExternalHostRow: View {
  let group: ExternalGroup
  var isExpanded = false
  /// Load N on hover, left of the count, or ✓ Previews.
  var preview: ExternalGroupPreview = .none
  var loadPreviews: () -> Void = {}
  /// Migrate N… beside Load N.
  var migrateCount = 0
  var isMigrationBusy = false
  var migrate: () -> Void = {}
  var toggle: () -> Void = {}
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: DesignMetrics.externalsTable.hostSpacing) {
      Button {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { toggle() }
      } label: {
        square.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Collapse" : "Expand")

      name
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: DesignMetrics.externalsTable.hostSpacing)
      ExternalGroupPreviewControl(preview: preview, isHovering: isHovering, load: loadPreviews)
      ExternalGroupMigrateControl(
        count: migrateCount, isHovering: isHovering, isBusy: isMigrationBusy, migrate: migrate)
      CountCapsule(group.rows.count, width: DesignMetrics.externalsTable.countWidth)
        .help("\(group.rows.count.formatted()) references")
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .padding(.horizontal, DesignMetrics.externalsTable.rowTrailing)
    .frame(height: DesignMetrics.externalsTable.hostRowHeight)
    .background(alignment: .topLeading) {
      if isExpanded {
        // The drop from the square's bottom to the row's bottom; the first
        // child row's line starts where this ends (the two rows touch).
        Rectangle()
          .fill(PinaxPalette.tree)
          .frame(
            width: DesignMetrics.externalsTable.treeLineWidth,
            height: DesignMetrics.externalsTable.treeFirstRise)
          .offset(
            x: DesignMetrics.externalsTable.treeX
              - DesignMetrics.externalsTable.treeLineWidth / 2,
            y: (DesignMetrics.externalsTable.hostRowHeight
              - DesignMetrics.externalsTable.hostSquareSide) / 2
              + DesignMetrics.externalsTable.hostSquareSide)
      }
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(height: 0.5)
    }
  }

  @ViewBuilder
  private var name: some View {
    if group.isFile {
      Text(group.host)
        .pinaxBody()
        .fontWeight(.semibold)
    } else {
      let parts = Self.hostParts(group.host)
      (
        Text(parts.sub).foregroundColor(.secondary)
          + Text(parts.base).fontWeight(.semibold)
      )
      .pinaxBody()
    }
  }

  @ViewBuilder
  private var square: some View {
    if group.isFile {
      PinaxStackedSquare(
        side: DesignMetrics.externalsTable.hostSquareSide,
        radius: DesignMetrics.externalsTable.hostSquareRadius,
        backColor: PinaxPalette.gray, showsStack: !isExpanded,
        stackOpacity: Self.stackOpacity(dark: colorScheme == .dark),
        ringColor: PinaxPalette.windowGround,
        ringWidth: DesignMetrics.externalsTable.hostStackRing,
        offset: DesignMetrics.externalsTable.hostStackOffset
      ) {
        ExternalDomainSquare(host: group.host, isFile: true)
      }
    } else {
      let token = PinaxPalette.domainToken(group.host)
      PinaxStackedSquare(
        side: DesignMetrics.externalsTable.hostSquareSide,
        radius: DesignMetrics.externalsTable.hostSquareRadius,
        backColor: PinaxPalette.color(token), showsStack: !isExpanded,
        stackOpacity: Self.stackOpacity(dark: colorScheme == .dark),
        ringColor: PinaxPalette.windowGround,
        ringWidth: DesignMetrics.externalsTable.hostStackRing,
        offset: DesignMetrics.externalsTable.hostStackOffset
      ) {
        ExternalDomainSquare(host: group.host)
      }
    }
  }

  static func stackOpacity(dark: Bool) -> Double {
    dark
      ? DesignMetrics.externalsTable.hostStackOpacityDark
      : DesignMetrics.externalsTable.hostStackOpacityLight
  }

  /// "upload.wikimedia.org" → ("upload.", "wikimedia.org"); two labels or
  /// fewer have no subdomain.
  static func hostParts(_ host: String) -> (sub: String, base: String) {
    let labels = host.split(separator: ".")
    guard labels.count > 2 else { return ("", host) }
    return (
      labels.dropLast(2).joined(separator: ".") + ".",
      labels.suffix(2).joined(separator: ".")
    )
  }

  /// The host's first letter past "www.", capitalised.
  static func avatarLetter(_ host: String) -> String {
    let name = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return name.first.map { String($0).uppercased() } ?? "?"
  }
}

/// A reference row: a 28 pt dashed placeholder (or
/// Your Domains' image), the file over its host-less path, the referencing
/// file with its L… capsule in Used In, and the Kind mark. The tree line
/// drops from the domain's square to this row's middle.
struct ExternalListRow: View {
  let row: ExternalReference
  let state: ExternalThumbnail?
  var isSelected = false
  /// The batch's mark on the small image, and an exception's
  /// symbol in the Refs column.
  var importState: ExternalImportCellState?
  var failure: ExternalImportFailure?
  var inFileGroup = false
  /// 0 for the first row under a domain; later siblings keep the vertical
  /// running through this row.
  var childIndex = 0
  /// How many rows the domain has: every row but the last runs the line on.
  var childCount = 1
  @Environment(\.externalsShowsUsedIn) private var showsUsedIn
  @Environment(\.externalsShowsSize) private var showsSize

  var body: some View {
    HStack(spacing: DesignMetrics.externalsTable.childSpacing) {
      ExternalThumbnailView(
        state: state, showsReason: false, isSelected: isSelected
      )
      .frame(
        width: DesignMetrics.externalsTable.thumbnail,
        height: DesignMetrics.externalsTable.thumbnail
      )
      .clipShape(
        RoundedRectangle(
          cornerRadius: DesignMetrics.externalsTable.thumbnailRadius, style: .continuous))
      .overlay { ExternalImportMark(state: importState) }
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
        Text(ExternalsView.filename(row))
          .pinaxBody()
          .fontWeight(.medium)
          .foregroundStyle(primary)
          .lineLimit(1)
          .truncationMode(.tail)
        // A file at the host's root has no second line; the name centres.
        let path = ExternalsView.directoryPath(row)
        if !path.isEmpty {
          Text(path)
            .pinaxTablePath()
            .foregroundStyle(tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .help(row.rawURL)
      Spacer(minLength: DesignMetrics.externalsTable.hostSpacing)
      if showsUsedIn {
        HStack(spacing: DesignMetrics.externalsTable.usedInSpacing) {
          Text(inFileGroup ? "" : ExternalsView.sourceFile(row))
            .pinaxFieldValue()
            .foregroundStyle(primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let line = ExternalsView.line(row) {
            LineCapsule(line, onAccent: isSelected)
          }
        }
        .frame(width: DesignMetrics.externalsTable.usedInWidth, alignment: .leading)
      }
      Text(ExternalsView.kindMark(row.kind))
        .pinaxTableKind()
        .foregroundStyle(tertiary)
        .lineLimit(1)
        .frame(width: DesignMetrics.externalsTable.kindWidth)
      if showsSize {
        ExternalSizeText(info: info, onAccent: isSelected)
          .frame(width: DesignMetrics.externalsTable.sizeWidth, alignment: .trailing)
      }
      Group {
        if let failure {
          Image(systemName: failure.symbol)
            .pinaxGlyph(DesignMetrics.externalsTable.kindSize)
            .foregroundStyle(ExternalsView.badgeColor(failure.category))
            .help(failure.explanation)
        } else {
          Color.clear
        }
      }
      .frame(width: DesignMetrics.externalsTable.refsWidth)
    }
    .padding(.leading, DesignMetrics.externalsTable.childLeading)
    .padding(.trailing, DesignMetrics.externalsTable.rowTrailing)
    .frame(height: DesignMetrics.externalsTable.childRowHeight)
    .background(alignment: .topLeading) {
      PinaxTreeElbow(
        x: DesignMetrics.externalsTable.treeX,
        startY: 0,
        endX: DesignMetrics.externalsTable.childLeading - DesignMetrics.externalsTable.treeGap,
        radius: DesignMetrics.externalsTable.treeRadius,
        continues: childIndex < childCount - 1
      )
      .stroke(
        PinaxPalette.tree,
        style: StrokeStyle(lineWidth: DesignMetrics.externalsTable.treeLineWidth))
      .accessibilityHidden(true)
      .allowsHitTesting(false)
    }
    .opacity(importState == .imported ? DesignMetrics.externals.importedOpacity : 1)
  }

  private var info: RemoteImageInfo? {
    if case let .loaded(_, info)? = state { return info }
    return nil
  }

  private var primary: AnyShapeStyle { isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary) }
  private var tertiary: AnyShapeStyle {
    isSelected
      ? AnyShapeStyle(.white.opacity(DesignMetrics.assetTable.selectedSecondaryOpacity))
      : AnyShapeStyle(.tertiary)
  }
}

// MARK: - Inspector

/// The inspector on Externals: the 130 pt preview with
/// its lock placeholder and one "Load preview" button, then Link → Used In
/// → Details as bands. Open File and Open URL are
/// icon buttons in Used In and Link; the title itself is drawn by
/// `InspectorTitleBar` in the column's toolbar strip.
struct ExternalInspector: View {
  @ObservedObject var model: ExternalsModel

  var body: some View {
    let rows = model.rows(model.selection)
    if rows.count > 1, let summary = model.selectionSummary(model.selection) {
      ExternalSelectionInspector(model: model, summary: summary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignMetrics.inspector.padding)
    } else if let row = rows.first {
      details(row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignMetrics.inspector.padding)
    } else {
      InspectorEmptyState(kind: .noReferenceSelected)
        .containerRelativeFrame(.vertical)
    }
  }

  private func details(_ row: ExternalReference) -> some View {
    let state = model.preview(row)
    return VStack(alignment: .leading, spacing: DesignMetrics.inspector.bandSpacing) {
      preview(row, state: state)
      if let info = model.imageInfo(row) {
        // The library's two pills, once loaded.
        HStack(spacing: DesignMetrics.inspectorStats.spacing) {
          StatPill.size(bytes: info.bytes)
            .frame(maxWidth: .infinity)
            .help("File size")
          StatPill.dimensions(
            PinaxFormat.dimensions(width: info.pixelWidth, height: info.pixelHeight) ?? "—"
          )
          .frame(maxWidth: .infinity)
          .help("Dimensions")
        }
      }
      linkBand(row)
      if let failure = model.importFailure(row) {
        importBand(row, failure: failure)
      }
      if let failure = model.migrationFailure(row) {
        migrationBand(failure)
      }
      usedInBand(row)
      detailsBand(row, state: state)
    }
  }

  /// The preview: 130 high. Your Domains' image loads through the
  /// gallery's pipeline; Other Domains shows a lock until its one
  /// "Load preview" button asks for that row alone.
  private func preview(_ row: ExternalReference, state: ExternalThumbnail?) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: DesignMetrics.externalsInspector.previewRadius, style: .continuous)
    return ZStack {
      if case .loaded = state {
        ExternalThumbnailView(state: state, contentMode: .fit)
      } else {
        VStack(spacing: DesignMetrics.externalsInspector.previewSpacing) {
          Image(systemName: ExternalsView.privacySymbol)
            .pinaxGlyph(DesignMetrics.externalsInspector.lockGlyph, weight: .light)
          Text(Self.previewNote(row, state: state))
            .pinaxPreviewNote()
            .lineLimit(2)
            .multilineTextAlignment(.center)
          if row.domain == .other, Self.canLoadPreview(state) {
            loadPreviewButton(row)
          }
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, DesignMetrics.spacing.m)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: DesignMetrics.externalsInspector.previewHeight)
    .background(PinaxPalette.band, in: shape)
    .clipShape(shape)
    .onAppear { model.loadThumbnail(row) }
  }

  /// The preview's sentence: "Not loaded from host" for Other
  /// Domains, a failure's reason when one came back, Loading… in flight.
  static func previewNote(_ row: ExternalReference, state: ExternalThumbnail?) -> String {
    switch state {
    case .loaded: return ""
    case .failed(let reason): return reason
    case .loading: return "Loading…"
    case nil: return "Not loaded from host"
    }
  }

  static func canLoadPreview(_ state: ExternalThumbnail?) -> Bool {
    switch state {
    case nil: return true
    case .failed: return true
    case .loading, .loaded: return false
    }
  }

  private func loadPreviewButton(_ row: ExternalReference) -> some View {
    Button {
      model.loadPreview(row)
    } label: {
      HStack(spacing: DesignMetrics.externalsInspector.loadSpacing) {
        Image(systemName: ExternalsView.loadPreviewSymbol)
          .pinaxGlyph(DesignMetrics.externalsInspector.loadGlyph)
        Text("Load preview").pinaxLoadPreview()
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, DesignMetrics.externalsInspector.loadHorizontalPadding)
      .frame(height: DesignMetrics.externalsInspector.loadHeight)
      .background(
        PinaxPalette.segment,
        in: RoundedRectangle(
          cornerRadius: DesignMetrics.externalsInspector.loadRadius, style: .continuous))
      .overlay {
        RoundedRectangle(
          cornerRadius: DesignMetrics.externalsInspector.loadRadius, style: .continuous
        )
        .strokeBorder(
          PinaxPalette.fieldLine, lineWidth: DesignMetrics.externalsInspector.loadLineWidth)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Load this image from its host")
  }

  /// Link: the file over "host › path", with Copy URL and Open URL
  /// as icon buttons.
  private func linkBand(_ row: ExternalReference) -> some View {
    InspectorBandSection(
      "Link", storageKey: "pinax.inspector.external.link"
    ) {
      HStack(spacing: DesignMetrics.externalsInspector.usedInSpacing) {
        if let host = URL(string: row.rawURL)?.host {
          ExternalDomainSquare(host: host)
        }
        VStack(alignment: .leading, spacing: DesignMetrics.inspectorFields.linkLineSpacing) {
          Text(ExternalsView.filename(row))
            .pinaxLinkName()
            .lineLimit(1)
            .truncationMode(.middle)
          Text(ExternalsView.linkLocation(row))
            .pinaxLinkPath()
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .help(row.rawURL)
        Spacer(minLength: DesignMetrics.externalsInspector.usedInSpacing)
        Button {
          model.perform(.copyURL(row.rawURL))
        } label: {
          Label("Copy URL", systemImage: ExternalsView.copySymbol)
        }
        .buttonStyle(.pinaxIcon)
        .help("Copy URL")
        let web = ExternalsModel.webURL(row)
        Button {
          if let web { model.perform(.openURL([web])) }
        } label: {
          Label("Open URL", systemImage: ExternalsView.openURLSymbol)
        }
        .buttonStyle(.pinaxIcon)
        .disabled(web == nil)
        .help("Open URL")
        // An icon button, as Copy and Open beside it.
        if !model.migrationURLs([row]).isEmpty {
          Button {
            Task { await model.migrate([row]) }
          } label: {
            Label("Migrate to Bucket…", systemImage: ExternalsView.migrateSymbol)
          }
          .buttonStyle(.pinaxIcon)
          .disabled(model.isMigrationBusy)
          .help(model.isMigrationBusy ? ExternalsModel.migrationBusyHelp : "Migrate to Bucket…")
        }
      }
    }
  }

  /// Migration: kept as a band only when a migration left this
  /// row behind, as Import's band is.
  private func migrationBand(_ failure: ExternalMigrationFailure) -> some View {
    InspectorBandSection(
      "Migration", storageKey: "pinax.inspector.external.migration"
    ) {
      VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
        Text(failure.status)
          .pinaxCaption()
          .foregroundStyle(PinaxPalette.orange)
        Text(failure.explanation)
          .pinaxSecondary()
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
  }

  /// Import: kept as a band only when an import left this row
  /// behind.
  private func importBand(_ row: ExternalReference, failure: ExternalImportFailure) -> some View {
    InspectorBandSection(
      "Import", storageKey: "pinax.inspector.external.import"
    ) {
      VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
        ExternalImportReason(failure: failure, text: failure.inspectorStatus)
        Text(failure.explanation)
          .pinaxSecondary()
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if case let .sameImage(key) = failure {
          Button { Task { await model.showInLibrary(key: key) } } label: {
            Text("Show in Library")
          }
          .controlSize(.small)
        }
      }
    }
  }

  /// Used In: every reference to this URL, the file over "project ›
  /// directory", its line capsule, and the Open File icon button that
  /// replaces the old full-width one.
  private func usedInBand(_ row: ExternalReference) -> some View {
    let references = model.references(to: row.rawURL)
    return InspectorBandSection(
      "Used In", storageKey: "pinax.inspector.external.usedIn",
      trailing: references.count.formatted()
    ) {
      VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
        if references.isEmpty {
          Text("Not used")
            .pinaxSecondary()
        } else {
          ForEach(references) { reference in
            HStack(spacing: DesignMetrics.externalsInspector.usedInSpacing) {
              Image(systemName: ExternalsView.fileSymbol)
                .pinaxGlyph(DesignMetrics.externalsInspector.usedInGlyph)
                .foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: DesignMetrics.inspectorFields.linkLineSpacing) {
                Text(ExternalsView.sourceFile(reference))
                  .pinaxLinkName()
                  .lineLimit(1)
                  .truncationMode(.middle)
                Text(ExternalsView.sourceDirectory(reference, showsProject: true))
                  .pinaxLinkPath()
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer(minLength: 0)
              if let line = ExternalsView.line(reference) {
                LineCapsule(line)
              }
              let file = model.fileURL(reference)
              Button {
                if let file { model.perform(.openFile([file])) }
              } label: {
                Label("Open File", systemImage: "arrow.up.forward.square")
              }
              .buttonStyle(.pinaxIcon)
              .disabled(file == nil)
              .help("Open File")
            }
          }
        }
      }
    }
  }

  /// Details: Remote with its state dot, Syntax, Domain. Domain also
  /// carries the backend.
  private func detailsBand(_ row: ExternalReference, state: ExternalThumbnail?) -> some View {
    InspectorBandSection(
      "Details", storageKey: "pinax.inspector.external.details"
    ) {
      InspectorFieldGrid {
        InspectorFieldRow("Remote") {
          HStack(spacing: DesignMetrics.externalsInspector.remoteDotSpacing) {
            Circle()
              .fill(Self.remoteDotColor(state))
              .frame(
                width: DesignMetrics.externalsInspector.remoteDot,
                height: DesignMetrics.externalsInspector.remoteDot)
            Text(Self.remote(state))
              .pinaxFieldValue()
              .lineLimit(2)
          }
        }
        if let info = model.imageInfo(row) {
          InspectorFieldRow("Type") {
            (Text(info.typeName) + Text(" · read from the image").foregroundStyle(.secondary))
              .pinaxFieldValue()
              .lineLimit(1)
          }
        }
        InspectorFieldRow("Syntax") {
          Text(Self.syntax(row))
            .pinaxFieldValue()
        }
        InspectorFieldRow("Domain") {
          Text(Self.domain(row))
            .pinaxFieldValue()
        }
      }
    }
  }

  /// The line under the name: where the reference stands, or — after an
  /// import left it — why.
  static func subtitle(_ row: ExternalReference, failure: ExternalImportFailure?) -> String {
    if let failure { return failure.inspectorSubtitle }
    return row.domain == .yours ? "On your domain, not in the catalog" : "On another host"
  }

  /// "Markdown image" / "HTML reference": the reference's syntax.
  static func syntax(_ row: ExternalReference) -> String {
    switch row.kind.lowercased() {
    case "markdown", "md", "mdx": return "Markdown image"
    case "html", "htm": return "HTML reference"
    default: return "\(row.kind.capitalized) reference"
    }
  }

  /// "Other · not yours", or the backend prefix's standing.
  static func domain(_ row: ExternalReference) -> String {
    guard let match = row.match else { return "Other · not yours" }
    return "\(match.backendSlug) · \(match.isCurrent ? "current" : "old") domain"
  }

  static func remoteDotColor(_ state: ExternalThumbnail?) -> Color {
    switch state {
    case .loaded: return PinaxPalette.liveDot
    case .failed: return PinaxPalette.remoteFailedDot
    case .loading, nil: return PinaxPalette.gray
    }
  }

  /// "Loaded", "404 · not found", "Not loaded" (Other Domains).
  static func remote(_ state: ExternalThumbnail?) -> String {
    switch state {
    case .loaded: "Loaded"
    case .failed(let reason): reason
    case .loading: "Loading…"
    case nil: "Not loaded"
    }
  }
}

/// Several rows' inspector: a strip of up to nine of the
/// selection's images, three across — the loaded ones drawn, the rest the
/// lock — then Load N Previews, Hosts with their refs, and Used In, whose
/// row opens its file.
struct ExternalSelectionInspector: View {
  @ObservedObject var model: ExternalsModel
  let summary: ExternalSelectionSummary

  static let stripLimit = 9
  static let stripColumns = 3

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.inspector.bandSpacing) {
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: DesignMetrics.spacing.s),
          count: Self.stripColumns),
        spacing: DesignMetrics.spacing.s
      ) {
        ForEach(summary.images.prefix(Self.stripLimit)) { row in
          cell(row)
        }
      }
      let sizes = model.selectionSizes(summary)
      if sizes.loadedBytes != nil || sizes.notLoaded > 0 {
        // The loaded images' total, and how many are not loaded.
        HStack(spacing: DesignMetrics.inspectorStats.spacing) {
          if let bytes = sizes.loadedBytes {
            StatPill(
              PinaxFormat.fileSize(bytes), systemImage: "arrow.up.and.down",
              tone: sizes.hasLarge ? .orange : .purple
            )
            .frame(maxWidth: .infinity)
            .help("Size of the loaded images")
          }
          if sizes.notLoaded > 0 {
            StatPill(sizes.notLoadedText, systemImage: ExternalsView.privacySymbol, tone: .gray)
              .frame(maxWidth: .infinity)
              .help("Sizes show once an image is loaded")
          }
        }
      }
      let migratable = model.migrationURLs(summary.rows).count
      if migratable > 0 {
        // The accent-filled primary, full width.
        Button {
          Task { await model.migrate(summary.rows) }
        } label: {
          Text(ExternalsModel.migrateInspectorTitle(migratable))
            .fontWeight(.semibold)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(PinaxPalette.accentFill)
        .controlSize(.large)
        .disabled(model.isMigrationBusy)
        .help(model.isMigrationBusy ? ExternalsModel.migrationBusyHelp : "Migrate to Bucket…")
      }
      let loadable = model.previewCandidates(summary.rows).count
      if loadable > 0 {
        Button {
          model.loadPreviews(summary.rows)
        } label: {
          Label(
            "Load \(PinaxFormat.count(loadable, singular: "Preview"))",
            systemImage: ExternalsView.loadPreviewSymbol)
            .fontWeight(.semibold)
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(PinaxPalette.accent)
      }
      InspectorBandSection(
        "Hosts", storageKey: "pinax.inspector.external.hosts",
        trailing: summary.hosts.count.formatted()
      ) {
        VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
          let sizes = model.selectionSizes(summary)
          ForEach(summary.hosts) { host in
            HStack(spacing: DesignMetrics.externalsInspector.usedInSpacing) {
              ExternalDomainSquare(host: host.host)
              Text(host.host)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 0)
              // The host's loaded bytes in their own column.
              ExternalSizeText(
                bytes: sizes.hostBytes[host.host], isLarge: sizes.largeHosts.contains(host.host)
              )
              .frame(width: DesignMetrics.externalsTable.sizeWidth, alignment: .trailing)
              Text(host.refs.formatted())
                .pinaxSecondary()
                .monospacedDigit()
                .frame(minWidth: DesignMetrics.externalsInspector.hostCountWidth, alignment: .trailing)
            }
          }
        }
      }
      InspectorBandSection(
        "Used In", storageKey: "pinax.inspector.external.selectionUsedIn",
        trailing: summary.rows.count.formatted()
      ) {
        VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
          ForEach(summary.rows) { row in
            usedInRow(row)
          }
        }
      }
    }
  }

  private func cell(_ row: ExternalReference) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: DesignMetrics.externalsInspector.previewRadius, style: .continuous)
    // The square comes first and the content sits on it: sized by its
    // content, a lone lock shrank the tile to the glyph.
    return Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if case .loaded = model.preview(row) {
          ExternalThumbnailView(state: model.preview(row))
        } else {
          Image(systemName: ExternalsView.privacySymbol)
            .foregroundStyle(.tertiary)
        }
      }
      .background(PinaxPalette.band, in: shape)
    .clipShape(shape)
    .onAppear { model.loadThumbnail(row) }
  }

  private func usedInRow(_ row: ExternalReference) -> some View {
    let file = model.fileURL(row)
    return Button {
      if let file { model.perform(.openFile([file])) }
    } label: {
      HStack(spacing: DesignMetrics.externalsInspector.usedInSpacing) {
        Text(ExternalsView.sourceFile(row))
          .pinaxLinkName()
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        if let line = ExternalsView.line(row) {
          LineCapsule(line)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(file == nil)
    .help(file == nil ? "" : "Open File")
  }
}

/// Whether the Externals table has room for its Used In column.
private struct ExternalsShowsUsedInKey: EnvironmentKey {
  static let defaultValue = true
}

/// Whether it has room for its Size column, which goes first.
private struct ExternalsShowsSizeKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var externalsShowsSize: Bool {
    get { self[ExternalsShowsSizeKey.self] }
    set { self[ExternalsShowsSizeKey.self] = newValue }
  }

  var externalsShowsUsedIn: Bool {
    get { self[ExternalsShowsUsedInKey.self] }
    set { self[ExternalsShowsUsedInKey.self] = newValue }
  }
}

/// A size in a column — monospaced digits,
/// right-aligned; orange with a small dot from the large line up; empty
/// when nothing is known.
struct ExternalSizeText: View {
  let bytes: Int64?
  var isLarge = false
  var onAccent = false

  init(bytes: Int64?, isLarge: Bool, onAccent: Bool = false) {
    self.bytes = bytes
    self.isLarge = isLarge
    self.onAccent = onAccent
  }

  init(info: RemoteImageInfo?, onAccent: Bool = false) {
    self.init(bytes: info?.bytes, isLarge: info?.isLarge ?? false, onAccent: onAccent)
  }

  var body: some View {
    if let bytes {
      HStack(spacing: DesignMetrics.externalsTable.largeDotSpacing) {
        if isLarge {
          Circle()
            .fill(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(PinaxPalette.orange))
            .frame(width: DesignMetrics.externalsTable.largeDot, height: DesignMetrics.externalsTable.largeDot)
        }
        Text(PinaxFormat.fileSize(bytes))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
      }
      .pinaxCaption()
      .foregroundStyle(style)
    } else {
      Color.clear.frame(height: 1)
    }
  }

  private var style: AnyShapeStyle {
    if onAccent { return AnyShapeStyle(.white) }
    return isLarge ? AnyShapeStyle(PinaxPalette.orange) : AnyShapeStyle(.secondary)
  }
}
