import AppKit
import CatalogCore
import SwiftUI

/// Renders the row tree from `SidebarModel.sections`. The `.tag` sits
/// on the row itself, never on a descendant inside an HStack (a tag there
/// breaks List selection), and row identities come namespaced from the
/// model, so a project and its usage entry are distinct selectable rows.
struct SidebarView: View {
  @ObservedObject var model: GalleryModel
  /// Which parent rows are open, by row id. View state, not persisted
  /// across launches: every launch starts with the years collapsed.
  @State private var expandedRows: Set<String> = []
  /// The Catalog roots already opened once by default.
  @State private var seededRoots: Set<String> = []
  /// The Library tab's shortcut sections that are
  /// open. View state like `expandedRows`: each window starts with them
  /// closed.
  @State private var openShortcuts: Set<LibraryShortcut> = []

  var body: some View {
    List(selection: Binding(
      get: { Optional(model.sidebarSelection) },
      set: { newValue in
        if let newValue {
          model.sidebarSelection = newValue
        }
      }
    )) {
      ForEach(model.sidebarSections) { section in
        Section {
          if section.shortcut.map(openShortcuts.contains) ?? true {
            ForEach(section.entries) { entry in
              SidebarNode(
                model: model, entry: entry, expandedRows: $expandedRows,
                depth: 0, treeLines: [])
            }
          }
          // An empty Tags group draws its
          // header and `+` alone, no `No Tags` row.
        } header: {
          HStack {
            Text(section.title)
              .pinaxGroupTitle()
            Spacer()
            if section.action == .addProject {
              if let projectSettings = model.projectSettings {
                SidebarProjectAdditionControl(model: model, settings: projectSettings)
              } else {
                Image(systemName: "plus")
                  .foregroundStyle(.tertiary)
              }
            }
            if section.action == .addTag {
              SidebarTagAdditionControl(model: model)
            }
            if let shortcut = section.shortcut {
              shortcutDisclosure(shortcut)
            }
          }
          .padding(.trailing, SidebarSectionHeader.trailingInset)
          .contextMenu {
            if model.navigator == .library {
              SidebarHeaderMenuItems(model: model, section: section)
            }
          }
        }
        // A titled `Section` in a sidebar list folds
        // by itself and draws the system triangle on hover, which pushed the
        // header's own controls left. A section opens and closes only by our
        // own arrow (the Library tab's shortcut sections).
        .collapsible(SidebarSectionHeader.systemFoldingEnabled)
      }
    }
    .listStyle(.sidebar)
    // One outline per navigator. Swapping
    // a tree that has expandable rows (the time navigator's years) for
    // another inside the same outline leaves a row view that belongs to no
    // row drawn over row 1, one more per round trip, and a few round trips
    // later SwiftUI traps casting a reused cell to a header — measured with
    // `DisclosureGroup` and with `OutlineGroup` alike, while switches
    // between flat trees left nothing behind. A fresh outline per navigator
    // has nothing to reuse. Measured before it was kept: sampled every
    // runloop turn through six switches, the sidebar's drawn pixels equal
    // the settled tree's from the first turn (no blank frame), and the
    // scroll view's frame and row 1's origin never move. The switcher sits
    // outside this identity, in the inset below, so it is not rebuilt.
    .id(model.navigator)
    // Measured: the inset sits
    // below the toolbar and the outline's first row starts below the
    // switcher, so the VStack fallback is not needed.
    .safeAreaInset(edge: .top, spacing: 0) {
      SidebarNavigatorPicker(model: model)
    }
    // With the outline focused, SwiftUI's inner split controller otherwise
    // consumes this nil-target toolbar action before the window coordinator.
    .onCommand(NSSelectorFromString("toggleInspector:")) {
      model.toggleInspector()
    }
    // Rows open and close by their own chevron, so ← and → are the
    // sidebar's, as the native outline's were: → opens the selected row,
    // ← closes it or, on a closed or childless row, selects its parent.
    .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
      handleDisclosureKey(press.key == .rightArrow ? .open : .close)
    }
    .environment(\.defaultMinListRowHeight, DesignMetrics.sidebarRow.height)
    // A Catalog root starts open, so its folders
    // show as the root level did before; once closed it stays closed.
    .onChange(of: model.catalogRootRowIDs, initial: true) { _, ids in
      SidebarDisclosure.seed(ids, seeded: &seededRoots, expanded: &expandedRows)
    }
    // The Time tab's current year (else the
    // newest) starts open, once per window; after that the user's choice.
    .onChange(of: model.timeDefaultOpenRowID, initial: true) { _, id in
      SidebarDisclosure.seed(id.map { [$0] } ?? [], seeded: &seededRoots, expanded: &expandedRows)
    }
  }

  /// The chevron on a shortcut section's header, › closed and
  /// ⌄ open.
  private func shortcutDisclosure(_ shortcut: LibraryShortcut) -> some View {
    let isOpen = openShortcuts.contains(shortcut)
    return Button {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        if isOpen {
          openShortcuts.remove(shortcut)
        } else {
          openShortcuts.insert(shortcut)
        }
      }
    } label: {
      Image(systemName: isOpen ? "chevron.down" : "chevron.right")
        .pinaxGroupTitle()
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isOpen ? "Collapse \(shortcut.title)" : "Expand \(shortcut.title)")
  }

  private func handleDisclosureKey(_ key: SidebarDisclosure.Key) -> KeyPress.Result {
    switch SidebarDisclosure.action(
      for: key, selection: model.sidebarSelection, in: model.sidebarSections,
      expanded: expandedRows)
    {
    case let .setExpanded(entry, isExpanded):
      SidebarDisclosure.setExpanded(
        isExpanded, entry: entry, expandedRows: &expandedRows, model: model)
      return .handled
    case let .select(selection):
      model.sidebarSelection = selection
      return .handled
    case .none:
      return .ignored
    }
  }
}

/// Values the section headers are built from.
enum SidebarSectionHeader {
  /// Whether the system may fold a section. Never: the shortcut sections'
  /// own arrow is the only way a section opens or closes.
  static let systemFoldingEnabled = false
  /// Space kept right of a header's controls. Measured in a 220 pt sidebar:
  /// the header's content box ends 2 pt in from the edge, a row's count
  /// capsule ends 16 in, so the controls (`+`, the shortcut arrow) pull in
  /// 12.5 to end on the capsule's right edge, the line the rows below end on.
  static let trailingInset: CGFloat = 12.5
}

/// One row and, when it is open, the rows under it — recursive, because
/// the Catalog tree has no depth limit. The rows sit flat in the
/// outline and draw their own state: no
/// chevron; a closed row that opens stacks a second square behind its own,
/// and its children hang from it on tree lines. The `.tag` is on the row
/// itself, never on a descendant inside it, where List selection breaks.
private struct SidebarNode: View {
  @ObservedObject var model: GalleryModel
  let entry: SidebarEntry
  @Binding var expandedRows: Set<String>
  /// How many levels below the section's first this row is.
  let depth: Int
  /// One flag per level above and at this row: whether the tree line of
  /// that level runs on below this row (a later sibling hangs from it).
  let treeLines: [Bool]

  var body: some View {
    if entry.isExpandable {
      row
        .tag(entry.selection)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
          setExpanded(!isExpanded)
        }
        .contextMenu { projectMenu }
      if isExpanded {
        ForEach(Array(entry.children.enumerated()), id: \.element.id) { index, child in
          SidebarNode(
            model: model, entry: child, expandedRows: $expandedRows,
            depth: depth + 1, treeLines: treeLines + [index < entry.children.count - 1])
        }
      }
    } else {
      row
        .tag(entry.selection)
        .contextMenu { projectMenu }
    }
  }

  /// A project row's menu, whether the row is open or not.
  @ViewBuilder
  private var projectMenu: some View {
    if case let .project(slug) = entry.selection {
      Button("Export Manifest…") {
        Task { await model.exportManifest(project: slug) }
      }
      .disabled(model.manifestExport?.isExporting == true)
    }
  }

  private var isExpanded: Bool { expandedRows.contains(entry.id) }

  private func setExpanded(_ isExpanded: Bool) {
    SidebarDisclosure.setExpanded(
      isExpanded, entry: entry, expandedRows: &expandedRows, model: model)
  }

  private var isSelected: Bool { model.sidebarSelection == entry.selection }

  /// A 30 pt row — colour square,
  /// name, and on the right the warning or the count capsule (34 wide).
  /// The selected row is a solid accentFill plate with white text,
  /// drawn by the row itself so it reads the same in a key and a
  /// background window. A row that opens does so by its square, which
  /// leaves the selection alone; the name and the rest select.
  private var row: some View {
    HStack(spacing: DesignMetrics.sidebarRow.iconSpacing) {
      if entry.isExpandable {
        Button {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { setExpanded(!isExpanded) }
        } label: {
          square.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
      } else {
        square
      }
      // A Storage root's bucket follows its slug in the
      // secondary colour and gives way first when the row is narrow.
      HStack(spacing: DesignMetrics.spacing.s) {
        Text(entry.label)
          .pinaxRowTitle()
          .lineLimit(1)
          .layoutPriority(1)
        if let detail = entry.detail {
          Text(detail)
            .pinaxSecondary()
            .lineLimit(1)
        }
      }
      .help(entry.help ?? "")
      Spacer(minLength: 0)
      trailing
    }
    .padding(.leading, SidebarDisclosure.leading(depth: depth))
    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    .frame(minHeight: DesignMetrics.sidebarRow.contentHeight)
    // After the frame, so the lines measure the 22 pt content, not the
    // HStack's own 18–20.
    .background(alignment: .topLeading) {
      if depth > 0 || (isExpanded && !entry.children.isEmpty) {
        SidebarTreeLines(
          depth: depth, continues: treeLines,
          hangsChildren: isExpanded && !entry.children.isEmpty,
          squareSide: SidebarEntrySquare.size(for: entry.iconTint).side)
          .stroke(
            PinaxPalette.tree,
            style: StrokeStyle(lineWidth: DesignMetrics.sidebarRow.treeLineWidth))
          .accessibilityHidden(true)
      }
    }
    .listRowBackground(SidebarSelectionPlate(isSelected: isSelected))
  }

  @ViewBuilder
  private var trailing: some View {
    if let warning = entry.warningCount {
      // ⚠ N on Archived while deletions did not finish,
      // visible from every place in the library.
      Label {
        Text("\(warning)")
          .monospacedDigit()
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .symbolRenderingMode(.multicolor)
      }
      .labelStyle(.titleAndIcon)
      .pinaxCaption()
      .help(
        warning == 1 ? "1 deletion didn’t finish" : "\(warning) deletions didn’t finish")
    } else if let count = entry.count {
      CountCapsule(count, onAccent: isSelected, width: DesignMetrics.sidebarRow.countWidth)
        .help(entry.countHelp)
    }
  }

  private var square: some View {
    SidebarEntrySquare(
      entry: entry, isSelected: isSelected,
      state: entry.isExpandable ? (isExpanded ? .open : .stacked) : .plain)
  }
}

/// A row's tree lines, in the row content's coordinates: the
/// content is `contentHeight` tall and the List adds half its vertical
/// inset above and below, so the lines run past the frame to meet the
/// rows around. A level's line drops from its parent square's bottom
/// middle; at this row's middle it turns right on a 7 pt arc and stops 3
/// before this row's square. A level whose later sibling is still to come
/// runs on through the row, and an open row starts its children's line
/// below its own square.
struct SidebarTreeLines: Shape {
  let depth: Int
  let continues: [Bool]
  let hangsChildren: Bool
  let squareSide: CGFloat

  func path(in rect: CGRect) -> Path {
    let metrics = DesignMetrics.sidebarRow.self
    let overhang = metrics.listVerticalInset / 2
    let top = rect.minY - overhang
    let bottom = rect.maxY + overhang
    let middle = rect.midY
    func squareLeft(_ level: Int) -> CGFloat {
      rect.minX + SidebarDisclosure.leading(depth: level)
    }
    func lineX(_ level: Int) -> CGFloat { squareLeft(level) + squareSide / 2 }

    var path = Path()
    for level in 0..<depth {
      let x = lineX(level)
      let runsOn = level < continues.count && continues[level]
      if level == depth - 1 {
        path.addPath(
          PinaxTreeElbow(
            x: x - rect.minX, startY: -overhang,
            endX: squareLeft(depth) - metrics.treeGap - rect.minX,
            radius: metrics.treeRadius, overhang: overhang, continues: runsOn
          ).path(in: rect))
      } else if runsOn {
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: bottom))
      }
    }
    if hangsChildren {
      let x = lineX(depth)
      path.move(to: CGPoint(x: x, y: middle + squareSide / 2))
      path.addLine(to: CGPoint(x: x, y: bottom))
    }
    return path
  }
}

/// Opening, closing and the arrow keys for the sidebar's rows,
/// shared by the square and the keyboard.
enum SidebarDisclosure {
  /// The row content's leading padding: every first-level square 6 in from
  /// the plate, so Catalog's folders line up with Library's squares; each
  /// level below 26 more, under the name of the row it opens from.
  static func leading(depth: Int) -> CGFloat {
    DesignMetrics.sidebarRow.plainLeading
      + CGFloat(depth) * DesignMetrics.sidebarRow.levelIndent
  }

  /// Opening a Catalog prefix whose level has not been fetched asks the
  /// model for it; the model queries each prefix once.
  @MainActor
  static func setExpanded(
    _ isExpanded: Bool, entry: SidebarEntry, expandedRows: inout Set<String>,
    model: GalleryModel
  ) {
    if isExpanded {
      expandedRows.insert(entry.id)
      if entry.expandsLazily {
        switch entry.selection {
        case let .keyPrefix(prefix, backend):
          Task { await model.loadFolderChildren(under: KeyPrefixLevel(backend: backend, prefix: prefix)) }
        case let .backend(slug):
          Task { await model.loadFolderChildren(under: KeyPrefixLevel(backend: slug, prefix: nil)) }
        case let .project(slug):
          Task { await model.loadProjectFolders(slug) }
        default:
          break
        }
      }
    } else {
      expandedRows.remove(entry.id)
    }
  }

  /// Opens each row in `ids` the first time it is offered, and never
  /// again: a row the user closed stays closed (Catalog roots, the Time
  /// tab's year).
  static func seed(_ ids: [String], seeded: inout Set<String>, expanded: inout Set<String>) {
    for id in ids where seeded.insert(id).inserted { expanded.insert(id) }
  }

  enum Key {
    case open
    case close
  }

  enum Action: Equatable {
    case setExpanded(SidebarEntry, Bool)
    case select(SidebarSelection)
  }

  /// What an arrow key does to the selected row, as the native outline
  /// did: → opens a closed row that has children; ← closes an open row,
  /// and on any other row selects the row it sits under. Nil leaves the
  /// key to the List.
  static func action(
    for key: Key, selection: SidebarSelection, in sections: [SidebarSection],
    expanded: Set<String>
  ) -> Action? {
    guard
      let (entry, parent) = find(
        selection, in: sections.flatMap(\.entries), parent: nil, expanded)
    else { return nil }
    let isOpen = expanded.contains(entry.id)
    switch key {
    case .open:
      return entry.isExpandable && !isOpen ? .setExpanded(entry, true) : nil
    case .close:
      if entry.isExpandable, isOpen { return .setExpanded(entry, false) }
      return parent.map { .select($0.selection) }
    }
  }

  /// The visible row with this selection, and the row it sits under.
  private static func find(
    _ selection: SidebarSelection, in entries: [SidebarEntry], parent: SidebarEntry?,
    _ expanded: Set<String>
  ) -> (SidebarEntry, SidebarEntry?)? {
    for entry in entries {
      if entry.selection == selection { return (entry, parent) }
      if expanded.contains(entry.id),
        let found = find(selection, in: entry.children, parent: entry, expanded)
      {
        return found
      }
    }
    return nil
  }
}

/// The selected row's ground (accentFill, corner 7), in the row's
/// background slot.
struct SidebarSelectionPlate: View {
  let isSelected: Bool
  /// The plate's clearance from the row's edges; the sidebar keeps the
  /// list's 8, Usage ▸ Files' full-width rows take 0.
  var inset: CGFloat = DesignMetrics.sidebarRow.selectionInset

  var body: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: DesignMetrics.sidebarRow.selectionRadius, style: .continuous)
        .fill(PinaxPalette.accentFill)
        .padding(.horizontal, inset)
    }
  }
}

/// A Library-tab section header's
/// menu, from `SidebarModel.headerMenu`.
private struct SidebarHeaderMenuItems: View {
  @ObservedObject var model: GalleryModel
  let section: SidebarSection

  var body: some View {
    let menu = SidebarModel.headerMenu(for: section, shown: model.libraryShortcuts)
    if let hides = menu.hides {
      Button("Hide Section") { model.setLibraryShortcut(hides, shown: false) }
      Divider()
    }
    Menu("Show Section") {
      ForEach(menu.showable, id: \.self) { shortcut in
        Button(shortcut.title) { model.setLibraryShortcut(shortcut, shown: true) }
      }
    }
    .disabled(!menu.canShow)
  }
}

/// The Tags header's `+`, drawn as the Projects
/// header's; it opens the Add Tag… popover on the selected assets.
private struct SidebarTagAdditionControl: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    Button {
      model.beginTagAddition()
    } label: {
      Image(systemName: "plus")
    }
    .buttonStyle(.borderless)
    .help("Add tag to the selection")
    .disabled(!model.canBeginTagAddition)
  }
}

private struct SidebarProjectAdditionControl: View {
  @ObservedObject var model: GalleryModel
  @ObservedObject var settings: ProjectSettingsModel

  var body: some View {
    Button {
      model.beginProjectAddition()
    } label: {
      Image(systemName: "plus")
    }
    .buttonStyle(.borderless)
    .help("Add project")
    .sheet(
      isPresented: Binding(
        get: { model.isProjectAdditionPresented },
        set: { presented in
          if !presented { model.cancelProjectAddition() }
        })
    ) {
      AddProjectSheet(
        model: settings,
        cancel: { model.cancelProjectAddition() },
        submit: { Task { await model.submitProjectAddition() } })
    }
    .alert(
      "Cannot Add Project",
      isPresented: Binding(
        get: { model.projectAdditionMessage != nil },
        set: { presented in
          if !presented { model.dismissProjectAdditionMessage() }
        })
    ) {
      Button("OK") { model.dismissProjectAdditionMessage() }
    } message: {
      Text(model.projectAdditionMessage ?? "")
    }
  }
}
