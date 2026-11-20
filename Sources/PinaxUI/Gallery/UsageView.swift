import CatalogCore
import SwiftUI

/// Usage: the current project's live references — or
/// every project's — by image or by file. Only matched references; the
/// unmatched ones are Externals.
///
/// A range bar heads the page — Images | Files, the domain menu, "N refs ·
/// N files · scanned …", Rescan. Images is the library's grid and table over
/// `model.rows`; Files is the referencing files on the left (236 pt, grouped
/// by project › directory) and the selected file's references on the right,
/// in a three-column grid.
///
/// Files is the default page; its
/// list sorts, narrows to a folder and collapses its groups, and its
/// divider drags; Images is cut into one section per file under a pinned
/// file strip.
struct UsageView: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      UsageScopeBar(model: model)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let message = model.errorMessage {
      FailureStateView(message: message)
    } else if let browser = model.usageBrowser {
      if browser.usage.scannedProjects.isEmpty {
        neverScanned
      } else if browser.images.isEmpty, let item = model.usageDomainItem {
        UsageDomainEmptyView(model: model, item: item)
      } else if browser.images.isEmpty {
        ContentUnavailableView(.noReferences)
      } else {
        switch model.usagePage {
        case .images:
          switch model.viewMode {
          case .grid: AssetGridView(model: model, usageCaption: .images)
          case .table: AssetTableView(model: model)
          }
        case .files:
          UsageFilesView(model: model, browser: browser)
        }
      }
    } else {
      ProgressView()
    }
  }

  /// No project in scope completed a scan: usage is unknown, not zero
  /// The action is the reports' own.
  @ViewBuilder
  private var neverScanned: some View {
    let scope = model.reportScopeProjects
    let slugs = scope.map(\.slug)
    let hasSources = !slugs.isEmpty && slugs.allSatisfy(model.sourcedProjects.contains)
    Group {
      if model.currentProjectSlug != nil, let project = scope.first {
        ContentUnavailableView(.noCompletedScan(project: project.name, hasSources: hasSources)) {
          UsageScanAction(model: model, projects: slugs, hasSources: hasSources)
        }
      } else {
        ContentUnavailableView(.usageUnknown(projects: scope.map(\.name))) {
          UsageScanAction(model: model, projects: slugs, hasSources: hasSources)
        }
      }
    }
  }
}

// MARK: - The range bar

/// The bar that replaces the page's title row: Images | Files, "Old
/// domains", the counts, Rescan. 38 high, on the scope ground, a hairline under
/// it.
struct UsageScopeBar: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    HStack(spacing: DesignMetrics.usageScope.spacing) {
      Picker("Page", selection: $model.usagePage) {
        ForEach(UsagePage.allCases) { page in
          Text(page.label).tag(page)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      oldDomains
      Spacer(minLength: DesignMetrics.usageScope.spacing)
      summary
      if let title = model.usageMoveTitle {
        UsageDomainMoveButton(model: model, lock: model.migrationLock, title: title)
      }
      if let sourced = rescanProjects {
        ScanNowButton(action: { model.onScanNow?(sourced) }, iconOnly: true)
          .buttonStyle(.pinaxIcon)
          .help("Scan Now")
      }
    }
    .padding(.horizontal, DesignMetrics.usageScope.horizontalPadding)
    .frame(height: DesignMetrics.usageScope.height)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  /// The domain menu, in the range bar's capsule.
  private var oldDomains: some View {
    UsageDomainMenu(model: model)
  }

  @ViewBuilder
  private var summary: some View {
    if let browser = model.usageBrowser {
      let summary = browser.rangeSummary(projects: model.reportScopeProjects)
      HStack(spacing: DesignMetrics.spacing.none) {
        ForEach(Array(summary.pieces.enumerated()), id: \.offset) { _, piece in
          Text(piece.text)
            .modifier(ScopeSummaryStyle(isFigure: piece.isFigure))
        }
      }
      .lineLimit(1)
      .help(summary.text)
    }
  }

  /// Rescan stands once there are references to re-read and a source to
  /// read; the empty state carries its own action.
  private var rescanProjects: [String]? {
    guard let browser = model.usageBrowser, !browser.usage.references.isEmpty else { return nil }
    let sourced = model.reportScopeProjects.map(\.slug).filter(model.sourcedProjects.contains)
    return sourced.isEmpty ? nil : sourced
  }

  private struct ScopeSummaryStyle: ViewModifier {
    let isFigure: Bool

    func body(content: Content) -> some View {
      if isFigure {
        content.pinaxScopeFigure()
      } else {
        content.pinaxScopeSummary()
      }
    }
  }
}

// MARK: - Usage ▸ Files

/// Files: the referencing files on the left — a header with the count and
/// the sort menu, then folder groups whose glyph opens and closes them and
/// whose path segments narrow the list — a divider that drags, and the
/// selected file's header and references on the right.
struct UsageFilesView: View {
  @ObservedObject var model: GalleryModel
  let browser: UsageBrowser

  /// An `HStack`, not an `HSplitView`. Measured: AppKit's split
  /// view coming or going (Images ⇄ Files, Orphans → Usage on Files) makes
  /// SwiftUI re-sync the window's toolbar, which removes the items the
  /// inspector mount appends and the mount appends them again — the
  /// toggle drops out and the toolbar reflows. The divider is our own drag
  /// handle instead (`UsageListDivider`).
  var body: some View {
    HStack(spacing: DesignMetrics.spacing.none) {
      UsageFileList(model: model)
        .frame(width: model.usageFilesListWidth)
      UsageListDivider(width: $model.usageFilesListWidth)
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
        if let file = selectedFile {
          fileHeader(file)
          Divider()
        }
        // A three-column contact sheet.
        AssetGridView(model: model, usageCaption: .files)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var selectedFile: UsageFile? {
    browser.files.first { $0.id == model.usageSelectedFileID }
  }

  // MARK: The header

  /// The selected file: a 28 pt file square, its name over "Modified
  /// 14 Dec 2025 · N images · N refs", and Open / Reveal.
  private func fileHeader(_ file: UsageFile) -> some View {
    HStack(spacing: DesignMetrics.usageFiles.headerSpacing) {
      ColorSquare(size: .header, color: PinaxPalette.gray, content: .symbol("doc.text"))
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
        Text(file.name)
          .pinaxUsageHeaderName()
          .lineLimit(1)
          .truncationMode(.middle)
        Text(Self.headerDetail(file, dates: model.usageFileDates[file.id]))
          .pinaxUsageHeaderDetail()
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if let url = model.usageFileURL(file) {
        ControlGroupCapsule {
          fileAction("Open File", systemImage: "arrow.up.right.square") {
            NSWorkspace.shared.open(url)
          }
          ControlGroupDivider()
          fileAction("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
      }
    }
    .padding(.horizontal, DesignMetrics.usageFiles.headerHorizontalPadding)
    .frame(height: DesignMetrics.usageFiles.headerHeight)
    .help(file.path)
  }

  /// The header's second line: "Modified 14 Dec 2025 · 2 images · 3 refs";
  /// no date for a file Pinax cannot open.
  static func headerDetail(
    _ file: UsageFile, dates: UsageFileDates?, locale: Locale = .current
  ) -> String {
    var parts: [String] = []
    if let modified = dates?.modified {
      parts.append("Modified \(UsageFileList.day(modified, locale: locale))")
    }
    parts.append(PinaxFormat.count(file.images.count, singular: "image"))
    parts.append(PinaxFormat.count(file.referenceCount, singular: "ref"))
    return parts.joined(separator: " · ")
  }

  private func fileAction(
    _ title: String, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .pinaxGlyph(DesignMetrics.iconButton.symbol)
        .foregroundStyle(.secondary)
        .frame(width: DesignMetrics.usageFiles.actionWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
  }
}

/// The file list: "N files" and the sort menu over the folder
/// groups. ↑ ↓ walk the visible files once the list has focus.
struct UsageFileList: View {
  @ObservedObject var model: GalleryModel
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: DesignMetrics.spacing.none) {
      header
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DesignMetrics.usageFiles.rowSpacing) {
            if let scope = model.usageFolderScope {
              scopeRow(scope)
            }
            if model.usageGroupsByFolder {
              ForEach(model.usageFileListGroups) { group in
                groupHeader(group)
                if !model.usageCollapsedGroups.contains(group.id) {
                  ForEach(group.files) { fileRow($0, indented: true) }
                }
              }
            } else {
              ForEach(model.usageVisibleFiles) { fileRow($0, indented: false) }
            }
          }
          .padding(.horizontal, DesignMetrics.usageFiles.listHorizontalPadding)
          .padding(.vertical, DesignMetrics.usageFiles.listVerticalPadding)
        }
        .scrollIndicators(.hidden)
        .onChange(of: model.usageSelectedFileID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      .focusable()
      .focusEffectDisabled()
      .focused($focused)
      .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
        model.moveUsageFileSelection(by: press.key == .upArrow ? -1 : 1)
        return .handled
      }
    }
  }

  // MARK: The header

  private var fileCount: Int {
    model.usageFileListGroups.reduce(0) { $0 + $1.files.count }
  }

  /// "55 files" and the sort menu (30 high, padded 14 leading, 8 trailing).
  private var header: some View {
    HStack(spacing: DesignMetrics.spacing.xs) {
      HStack(spacing: DesignMetrics.spacing.none) {
        Text(fileCount.formatted()).pinaxScopeFigure()
        Text(" " + UsageBrowser.RangeSummary.word(fileCount, "file")).pinaxScopeSummary()
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      sortMenu
    }
    .padding(.leading, DesignMetrics.usageRevision.listHeaderLeading)
    .padding(.trailing, DesignMetrics.usageRevision.listHeaderTrailing)
    .frame(height: DesignMetrics.usageRevision.listHeaderHeight)
  }

  /// Sort By (Name, Date Modified, Date Created, References), the
  /// field's two directions, and Group by Folder.
  private var sortMenu: some View {
    Menu {
      Section("Sort By") {
        ForEach(UsageFileSortField.allCases) { field in
          Toggle(
            field.label,
            isOn: Binding(
              get: { model.usageFileSort.field == field },
              set: { if $0 { model.usageFileSort = .picking(field) } }))
        }
      }
      Section {
        let labels = model.usageFileSort.field.directionLabels
        Toggle(labels.descending, isOn: direction(ascending: false))
        Toggle(labels.ascending, isOn: direction(ascending: true))
      }
      Section {
        Toggle("Group by Folder", isOn: $model.usageGroupsByFolder)
      }
    } label: {
      HStack(spacing: DesignMetrics.spacing.xs) {
        Image(systemName: "arrow.up.arrow.down")
          .imageScale(.small)
        Text(model.usageFileSort.field.label)
        Image(systemName: "chevron.down")
          .imageScale(.small)
      }
      .pinaxListSortLabel()
      .contentShape(Rectangle())
    }
    // A plain button label, so the menu draws the label's own type and ink
    // instead of the borderless menu's body text.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Sort the files")
  }

  private func direction(ascending: Bool) -> Binding<Bool> {
    Binding(
      get: { model.usageFileSort.ascending == ascending },
      set: { if $0 { model.usageFileSort.ascending = ascending } })
  }

  // MARK: Scope and groups

  /// A narrowed list's way back: "All Files › astro › src", each a step up.
  private func scopeRow(_ scope: UsageFolderScope) -> some View {
    let steps = [UsageFolderScope(project: scope.project, components: [])]
      + scope.components.indices.map {
        UsageFolderScope(project: scope.project, components: Array(scope.components[...$0]))
      }
    return HStack(spacing: DesignMetrics.usageRevision.groupSpacing) {
      Button("All Files") { model.usageFolderScope = nil }
        .buttonStyle(.usageSegment)
      ForEach(steps, id: \.self) { step in
        Text("›").foregroundStyle(.tertiary)
        let label = step.components.last ?? step.project
        if step == scope {
          Text(label).foregroundStyle(.primary)
        } else {
          Button(label) { model.usageFolderScope = step }
            .buttonStyle(.usageSegment)
        }
      }
      Spacer(minLength: 0)
    }
    .pinaxUsageGroupHeader()
    .lineLimit(1)
    .frame(height: DesignMetrics.usageRevision.groupHeaderHeight)
  }

  /// The folder — filled open, outlined closed — toggles the group; each
  /// segment of "astro › src › content › blog" narrows the list to it.
  private func groupHeader(_ group: UsageFileListGroup) -> some View {
    let isOpen = !model.usageCollapsedGroups.contains(group.id)
    return HStack(spacing: DesignMetrics.usageRevision.groupSpacing) {
      Button {
        model.toggleUsageGroup(group.id)
      } label: {
        Image(systemName: isOpen ? "folder.fill" : "folder")
          .pinaxGlyph(DesignMetrics.usageRevision.groupGlyph)
      }
      .buttonStyle(.usageSegment)
      .help(isOpen ? "Collapse" : "Expand")
      .accessibilityLabel(isOpen ? "Collapse \(group.title)" : "Expand \(group.title)")
      ForEach(Array(group.segments.enumerated()), id: \.offset) { index, segment in
        if index > 0 { Text("›").foregroundStyle(.tertiary) }
        Button(segment.label) { model.usageFolderScope = segment.scope }
          .buttonStyle(.usageSegment)
          .help("Show only \(segment.scope.components.last ?? segment.scope.project)")
      }
      Spacer(minLength: 0)
      Text(group.files.count.formatted())
        .monospacedDigit()
    }
    .pinaxUsageGroupHeader()
    .lineLimit(1)
    .truncationMode(.middle)
    .frame(height: DesignMetrics.usageRevision.groupHeaderHeight)
    .contentShape(Rectangle())
    .onTapGesture { model.toggleUsageGroup(group.id) }
  }

  // MARK: Rows

  /// One file: its name over its date, its reference count, on accentFill
  /// when it is the one the grid is showing.
  private func fileRow(_ file: UsageFile, indented: Bool) -> some View {
    let selected = file.id == model.usageSelectedFileID
    let date = UsageFileList.rowDate(
      model.usageFileDates[file.id], sort: model.usageFileSort.field)
    return Button {
      model.usageSelectedFileID = file.id
      focused = true
    } label: {
      HStack(spacing: DesignMetrics.spacing.s) {
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
          Text(file.name)
            .pinaxUsageFileName()
            .lineLimit(1)
            .truncationMode(.middle)
          if let date {
            Text(date)
              .pinaxUsageFileDate()
              .foregroundStyle(
                selected
                  ? AnyShapeStyle(.white.opacity(DesignMetrics.usageFiles.selectedSecondaryOpacity))
                  : AnyShapeStyle(.tertiary))
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        CountCapsule(file.referenceCount, onAccent: selected)
      }
      .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .padding(.leading, indented ? DesignMetrics.usageRevision.rowLeadingIndent : DesignMetrics.usageFiles.rowHorizontalPadding)
      .padding(.trailing, DesignMetrics.usageFiles.rowHorizontalPadding)
      .frame(height: DesignMetrics.usageFiles.rowHeight)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(SidebarSelectionPlate(isSelected: selected, inset: 0))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .id(file.id)
    .help(file.path)
    .contextMenu {
      if let url = model.usageFileURL(file) {
        Button("Open File") { NSWorkspace.shared.open(url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        if let url = model.usageFileURL(file) { NSWorkspace.shared.open(url) }
      })
  }

  /// A row's second line: the creation date when the list sorts by it,
  /// else the modification date; nothing for a file Pinax cannot open.
  static func rowDate(
    _ dates: UsageFileDates?, sort: UsageFileSortField, locale: Locale = .current
  ) -> String? {
    let date = sort == .created ? dates?.created : dates?.modified
    return date.map { day($0, locale: locale) }
  }

  /// "14 Dec 2025", the library's day style.
  static func day(_ date: Date, locale: Locale = .current) -> String {
    date.formatted(.dateTime.locale(locale).month(.abbreviated).day().year())
  }
}

// MARK: - Usage ▸ Images' file strip

/// A file section's header on Usage ▸ Images: the doc square, the file
/// name, "project › directory", "N images · N refs" and Show in Files. It
/// stands on the pinned plate in flow too, so each file reads as a band.
struct UsageFileSectionHeader: View {
  @ObservedObject var model: GalleryModel
  let file: UsageFile

  var body: some View {
    HStack(spacing: DesignMetrics.usageRevision.stripSpacing) {
      ColorSquare(size: .sidebar, color: PinaxPalette.gray, content: .symbol("doc.text"))
      Text(file.name)
        .pinaxUsageFileName()
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
      Text(Self.location(file, browser: model.usageBrowser))
        .foregroundStyle(.tertiary)
        .pinaxUsageHeaderDetail()
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 0)
      Text(
        [
          PinaxFormat.count(file.images.count, singular: "image"),
          PinaxFormat.count(file.referenceCount, singular: "ref"),
        ].joined(separator: " · ")
      )
      .pinaxUsageHeaderDetail()
      .lineLimit(1)
      .fixedSize()
      Button {
        model.showUsageFileInFiles(file.id)
      } label: {
        HStack(spacing: DesignMetrics.spacing.xs) {
          Text("Show in Files")
          Image(systemName: "chevron.right").imageScale(.small)
        }
        .foregroundStyle(PinaxPalette.accent)
        .pinaxUsageHeaderDetail()
      }
      .buttonStyle(.usageSegment)
      .fixedSize()
    }
    .help(file.path)
    .pinnedSectionPlate(alwaysPinned: true)
  }

  /// "astro › src/content/blog", the source label off.
  static func location(_ file: UsageFile, browser: UsageBrowser?) -> String {
    let directory = browser?.displayDirectoryComponents(file) ?? []
    return ([file.projectSlug] + directory).joined(separator: " › ")
  }
}

// MARK: - The domain menu

/// All Domains, then a section per backend with each domain, its role and
/// the scope's references; Unused greyed. The capsule says what is chosen.
struct UsageDomainMenu: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    let item = model.usageDomainItem
    Menu {
      Button {
        model.usageDomain = nil
        model.usageOldDomainsOnly = false
      } label: {
        checked(model.usageDomain == nil && !model.usageOldDomainsOnly,
          "All Domains   \(model.usageAllDomainsLinks.formatted())")
      }
      ForEach(model.usageDomainSections, id: \.backend) { section in
        Divider()
        Section(section.backend) {
          ForEach(section.items) { domain in
            Button {
              model.usageDomain = domain.prefix
            } label: {
              checked(model.usageDomain == domain.prefix, Self.itemText(domain))
            }
            .disabled(domain.isUnused && model.usageDomain != domain.prefix)
            .help(domain.isUnused ? "No links in your files" : domain.prefix)
          }
        }
      }
    } label: {
      HStack(spacing: DesignMetrics.usageOutlineCapsule.spacing) {
        Image(systemName: "globe")
          .pinaxGlyph(DesignMetrics.usageOutlineCapsule.glyph)
          .foregroundStyle(.secondary)
        Text(Self.title(item: item, oldDomainsOnly: model.usageOldDomainsOnly))
          .lineLimit(1)
        if item?.isCurrent == false {
          Text("Old")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 4)
            .foregroundStyle(.secondary)
            .background(Capsule().strokeBorder(.secondary.opacity(0.6)))
        }
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .pinaxMenuCapsule()
    .help(item?.prefix ?? "Domain")
    .accessibilityLabel("Domain")
  }

  /// The capsule: the chosen host, All Domains, or the Overview's Old
  /// Domains filter while it holds.
  static func title(item: GalleryModel.UsageDomainItem?, oldDomainsOnly: Bool) -> String {
    if let item { return item.host }
    return oldDomainsOnly ? "Old Domains" : "All Domains"
  }

  /// "img.example.com   Current · 221" / "i.example.com   Old · Unused".
  static func itemText(_ item: GalleryModel.UsageDomainItem) -> String {
    "\(item.host)   \(item.isCurrent ? "Current" : "Old") · \(item.isUnused ? "Unused" : item.links.formatted())"
  }

  @ViewBuilder
  private func checked(_ on: Bool, _ text: String) -> some View {
    if on {
      Label(text, systemImage: "checkmark")
    } else {
      Text(text)
    }
  }
}

/// The bar's Move N Links to Current…: after a thin line, the accent text
/// button; greyed while a migration runs.
struct UsageDomainMoveButton: View {
  @ObservedObject var model: GalleryModel
  @ObservedObject var lock: MigrationLock
  let title: String

  var body: some View {
    HStack(spacing: DesignMetrics.usageScope.spacing) {
      Rectangle()
        .fill(.separator)
        .frame(width: 1, height: 14)
      Button(title) { model.moveUsageDomainToCurrent() }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(lock.isBusy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(PinaxPalette.accent))
        .disabled(lock.isBusy)
        .help(lock.isBusy ? MigrationLock.busyHelp : "")
        .lineLimit(1)
        .fixedSize()
    }
  }
}

/// A chosen domain with nothing on it: No Links on host, a line that it
/// can leave Old domains, and the way to Settings. Only a hint.
struct UsageDomainEmptyView: View {
  @ObservedObject var model: GalleryModel
  let item: GalleryModel.UsageDomainItem
  @Environment(\.openSettings) private var openSettings

  static func notInCatalog(_ links: Int) -> String {
    links == 1
      ? "1 link points to an image not in the catalog."
      : "\(links.formatted()) links point to images not in the catalog."
  }

  var body: some View {
    ContentUnavailableView {
      // Links only to images not in the catalog
      // leave the list empty but the domain in use.
      Label(item.isUnused ? "No Links on \(item.host)" : item.host, systemImage: "globe")
    } description: {
      if !item.isUnused {
        Text(Self.notInCatalog(item.links))
      } else if !item.isCurrent {
        Text("You can remove it from Old domains.")
      }
    } actions: {
      Button("Open Backends Settings") {
        model.onOpenBackendSettings?(item.backend)
        openSettings()
      }
    }
  }
}
