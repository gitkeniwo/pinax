import AppKit
import CatalogCore
import SwiftUI

/// The table view mode. It never orders rows itself: the
/// rows arrive in the query's order, and a column-header click writes the
/// model's one `sort` — the same order View ▸ Sort By and the jump bar show
/// — which reloads from the first page. Sorting the loaded page here would
/// put the biggest of 120 rows first, not the biggest in the library.
///
/// In upload-date order with Group by Month on, the rows come
/// in the grid's own month sections (`groupedRows`, one cut for both); the
/// row height is the table's own rung, which View ▸ Make Bigger / Make
/// Smaller and the toolbar slider move.
///
/// Each row carries the grid's context menu
/// (`AssetContextMenuItems`, the same targets): right-click outside the
/// selection acts on that row alone (and selects it), inside a selection of
/// two or more on the selection.
struct AssetTableView: View {
  @ObservedObject var model: GalleryModel

  @State private var columns = TableColumnCustomization<GalleryModel.Row>()

  var body: some View {
    // Row selection is the model's selection set itself: `Table`
    // brings its own ⌘ / ⇧ clicks and keyboard.
    Table(
      of: GalleryModel.Row.self, selection: $model.selectedIDs, sortOrder: sortOrder,
      columnCustomization: customization
    ) {
      TableColumn("") { row in
        // The row's height follows the thumbnail: automatic row heights
        // add `thumbnailInset` around it (measured).
        if !row.isUsageReference {
          let side = model.tableRowHeight - DesignMetrics.table.thumbnailInset
          ThumbnailView(item: row.item, cache: model.thumbnails)
            .frame(width: side, height: side)
            .clipShape(
              RoundedRectangle(
                cornerRadius: DesignMetrics.assetTable.thumbnailRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
              Self.formatBlock(row)
                .padding(DesignMetrics.assetTable.formatBlockInset)
            }
        }
      }
      .width(model.tableRowHeight)
      TableColumn("Name", sortUsing: Self.comparator(.name)) { row in
        // Middle truncation, as in the grid: names that share a prefix
        // stay apart by their endings.
        Text(Self.name(row))
          .pinaxBody()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
          .lineLimit(1)
          .truncationMode(.middle)
          // The context menu's Add Tag… / Edit Note… popover hangs here.
          .assetContextEditorPopover(model: model, row: row)
      }
      TableColumn("Uses") { row in
        Text(Self.uses(row))
          .pinaxBody()
          .monospacedDigit()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .customizationID(Self.usesColumn)
      TableColumn("Kind", sortUsing: Self.comparator(.kind)) { row in
        Text(Self.kind(row))
          .pinaxBody()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
      }
      // Sortable; the query orders by the host.
      TableColumn("Domain", sortUsing: Self.comparator(.domain)) { row in
        Text(Self.domain(row))
          .pinaxBody()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(Self.domainHelp(row))
      }
      .customizationID(Self.domainColumn)
      // Off by default outside Usage, opened from
      // the header's menu.
      .defaultVisibility(.hidden)
      TableColumn("Project") { row in
        Text(Self.project(row))
          .pinaxBody()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
          .lineLimit(1)
      }
      .customizationID(Self.projectColumn)
      trailingColumns
    } rows: {
      if model.shownSelection == .usage {
        ForEach(model.rows) { row in
          UsageImageTableRow(model: model, row: row)
        }
      } else if model.showsRowsByMonth {
        ForEach(model.groupedRows, id: \.month) { group in
          AssetTableSection(
            model: model, month: group.month, rows: group.rows)
        }
      } else {
        ForEach(model.rows) { row in
          AssetTableRow(model: model, row: row)
        }
      }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    // AppKit's highlight is off and the accentFill plate is drawn
    // behind the selected row's cells (SwiftUI Table has no row background).
    .background(
      AssetTableSelectionPlate(
        selectedIndexes: Self.selectedRowIndexes(in: model),
        enabled: model.shownSelection != .usage))
    // A row's double-click opens Quick Look on the selection, as a grid
    // cell's does. The menu stays the rows' own: this one
    // is empty, so it shows nothing.
    .contextMenu(forSelectionType: GalleryModel.Row.ID.self) { _ in
    } primaryAction: { _ in
      model.openQuickLook()
    }
  }


  /// The columns after Project, in their own builder: a table builder holds
  /// ten columns, and Source is the eleventh.
  @TableColumnBuilder<GalleryModel.Row, KeyPathComparator<GalleryModel.Row>>
  private var trailingColumns: some TableColumnContent<GalleryModel.Row, KeyPathComparator<GalleryModel.Row>> {
    TableColumn("Size", sortUsing: Self.comparator(.byteSize)) { row in
      if !row.isUsageReference {
        Text(PinaxFormat.fileSize(row.item.asset.byteSize))
          .pinaxBody()
          .monospacedDigit()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    TableColumn("Dimensions") { row in
      if !row.isUsageReference {
        Text(
          PinaxFormat.dimensions(width: row.item.asset.width, height: row.item.asset.height)
            ?? "—"
        )
        .pinaxBody()
        .monospacedDigit()
        .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    TableColumn("Uploaded", sortUsing: Self.comparator(.uploadedAt)) { row in
      if !row.isUsageReference {
        Text(PinaxFormat.date(row.item.asset.uploadedAt, style: .dayTime))
          .pinaxBody()
          .monospacedDigit()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
          .lineLimit(1)
      }
    }
    .width(min: Self.uploadedColumnWidth)
    // Between Uploaded and Key; Pinax rows are blank. Not tied
    // to the grid's Show Source Tags or its style.
    TableColumn("Source", sortUsing: Self.comparator(.source)) { row in
      if !row.isUsageReference {
        Text(Self.source(row))
          .pinaxBody()
          .foregroundStyle(Self.textStyle(selected: Self.isSelected(row, in: model)))
          .lineLimit(1)
      }
    }
    .customizationID(Self.sourceColumn)
    TableColumn("Key") { row in
      if !row.isUsageReference {
        Text(row.item.asset.key)
          .pinaxMono()
          .foregroundStyle(Self.secondaryStyle(selected: Self.isSelected(row, in: model)))
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  /// A row's text on the table's selected plate: white, or white 75 % for
  /// secondary words.
  static func textStyle(selected: Bool) -> AnyShapeStyle {
    selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
  }

  static func secondaryStyle(selected: Bool) -> AnyShapeStyle {
    selected
      ? AnyShapeStyle(.white.opacity(DesignMetrics.assetTable.selectedSecondaryOpacity))
      : AnyShapeStyle(.secondary)
  }

  static func isSelected(_ row: GalleryModel.Row, in model: GalleryModel) -> Bool {
    model.selectedIDs.contains(row.id)
  }

  /// The row's format block: the format's colour on a
  /// 13 pt square over the thumbnail's trailing bottom corner.
  @ViewBuilder
  static func formatBlock(_ row: GalleryModel.Row) -> some View {
    let mime = row.item.asset.mime
    ColorSquare(
      size: .caption,
      color: PinaxPalette.color(PinaxPalette.formatToken(mime: mime)),
      content: .letters(PinaxPalette.formatBadge(mime: mime)))
      .overlay {
        RoundedRectangle(cornerRadius: DesignMetrics.assetTable.formatBlockRadius)
          .strokeBorder(
            .white.opacity(0.35), lineWidth: DesignMetrics.assetTable.formatBlockLineWidth)
      }
  }

  /// The selected rows' positions in the table, month headers counted.
  /// Usage's disclosure rows do not map onto `rows` one to one, so its
  /// table keeps the system selection (`enabled: false` above).
  static func selectedRowIndexes(in model: GalleryModel) -> IndexSet {
    guard model.shownSelection != .usage else { return [] }
    var indexes = IndexSet()
    var index = 0
    if model.showsRowsByMonth {
      for group in model.groupedRows {
        index += 1
        for row in group.rows {
          if model.selectedIDs.contains(row.id) { indexes.insert(index) }
          index += 1
        }
      }
    } else {
      for row in model.rows {
        if model.selectedIDs.contains(row.id) { indexes.insert(index) }
        index += 1
      }
    }
    return indexes
  }

  static let usesColumn = "uses"
  static let domainColumn = "domain"
  static let projectColumn = "project"
  static let sourceColumn = "source"

  /// The Source column's words: PicGo and Bucket imports by name; Pinax
  /// uploads, and the two kinds with no copy yet, blank.
  static func source(_ row: GalleryModel.Row) -> String {
    SourceCaption.name(of: AssetSource.of(meta: row.item.asset.meta)) ?? ""
  }

  /// Uses and Domain only on Usage, Project only there
  /// under All Projects — by column visibility, since a column inside an
  /// `if` needs macOS 14.4. The columns the user can move are only these.
  static func visibleUsageColumns(
    selection: SidebarSelection, currentProjectSlug: String?
  ) -> Set<String> {
    guard selection == .usage else { return [] }
    return currentProjectSlug == nil
      ? [usesColumn, domainColumn, projectColumn] : [usesColumn, domainColumn]
  }

  private var customization: Binding<TableColumnCustomization<GalleryModel.Row>> {
    Binding(
      get: {
        var shown = columns
        let visible = Self.visibleUsageColumns(
          selection: model.shownSelection, currentProjectSlug: model.currentProjectSlug)
        let usage = model.shownSelection == .usage
        for id in [Self.usesColumn, Self.domainColumn, Self.projectColumn] {
          // Outside Usage, Domain is the user's to show.
          if id == Self.domainColumn, !usage { continue }
          shown[visibility: id] = visible.contains(id) ? .visible : .hidden
        }
        return shown
      },
      set: { columns = $0 })
  }

  /// Uses: an image's reference count; a reference's line, "L12".
  static func uses(_ row: GalleryModel.Row) -> String {
    switch row.usage {
    case let .image(uses, _, _): return uses.formatted()
    case let .reference(reference): return reference.line.map { "L\($0)" } ?? "—"
    case .line, nil: return ""
    }
  }

  /// Usage's reference: Old or Current. An image: its backend's Current
  /// host.
  static func domain(_ row: GalleryModel.Row) -> String {
    switch row.usage {
    case let .reference(reference)?: return reference.reference.isOldDomain ? "Old" : "Current"
    case .image?, .line?: return ""
    case nil: return DomainHost.host(row.item.backend.urlPrefix)
    }
  }

  static func domainHelp(_ row: GalleryModel.Row) -> String {
    row.usage == nil ? row.item.backend.slug : ""
  }

  static func project(_ row: GalleryModel.Row) -> String {
    guard case let .reference(reference) = row.usage else { return "" }
    return reference.reference.projectSlug
  }

  /// A month row: the grid header's words on one line, "January 2026 · 8".
  static func monthTitle(_ month: String, count: Int) -> String {
    let title = PinaxFormat.monthTitle(month)
    return "\(title.month) \(title.year) \(MonthSectionHeader.countText(count))"
  }

  /// The Uploaded column's minimum: the widest date and time this locale
  /// writes in the column's font — body with monospaced digits, so every
  /// day and hour is as wide as any other and only the month name varies —
  /// plus the cell's padding, so the time is never cut off.
  static let uploadedColumnWidth: CGFloat = widestUploadedText.rounded(.up)
    + DesignMetrics.table.cellPadding

  /// The widest `PinaxFormat.date(.dayTime)` string, one per month.
  static var widestUploadedText: CGFloat {
    let body = NSFont.preferredFont(forTextStyle: .body)
    let font = NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
    return (1...12).map { month in
      let date = String(format: "2026-%02d-15T12:00:00Z", month)
      return (PinaxFormat.date(date, style: .dayTime) as NSString)
        .size(withAttributes: [.font: font]).width
    }.max() ?? 0
  }

  /// The Kind column: the grid cell's format chip, "JPEG"; a reference's
  /// kind, "markdown".
  static func kind(_ row: GalleryModel.Row) -> String {
    if case let .reference(reference) = row.usage { return reference.reference.kind }
    return PinaxFormat.shortKind(mime: row.item.asset.mime)
  }

  /// The model's `sort` as the table's sort order: the header arrow shows
  /// the one order, and a header click writes it back. A comparator on a
  /// column this table does not sort by is ignored.
  var sortOrder: Binding<[KeyPathComparator<GalleryModel.Row>]> {
    Binding(
      get: {
        [Self.comparator(
          model.sort.field, order: model.sort.direction == .ascending ? .forward : .reverse)]
      },
      set: { order in
        // Usage keeps its own order, most used first.
        guard model.shownSelection != .usage, let first = order.first,
          let field = AssetSort.Field.allCases.first(where: {
            Self.comparator($0).keyPath == first.keyPath
          })
        else { return }
        model.sort = AssetSort(
          field: field, direction: first.order == .forward ? .ascending : .descending)
      })
  }

  /// One comparator per sortable column. Only its key path and order are
  /// read — the query does the ordering — so the key path is what names the
  /// field.
  static func comparator(
    _ field: AssetSort.Field, order: SortOrder = .forward
  ) -> KeyPathComparator<GalleryModel.Row> {
    switch field {
    case .uploadedAt: return KeyPathComparator(\.item.asset.uploadedAt, order: order)
    case .name: return KeyPathComparator(\.tableName, order: order)
    case .byteSize: return KeyPathComparator(\.item.asset.byteSize, order: order)
    case .kind: return KeyPathComparator(\.item.asset.mime, order: order)
    case .source: return KeyPathComparator(\.sourceSortKey, order: order)
    case .domain: return KeyPathComparator(\.domainSortKey, order: order)
    }
  }

  /// The Name column: the original filename, else the key's last segment;
  /// a reference's file.
  static func name(_ row: GalleryModel.Row) -> String {
    if case let .reference(reference) = row.usage { return reference.file }
    return row.tableName
  }
}

extension GalleryModel.Row {
  var isUsageReference: Bool {
    if case .reference = usage { return true }
    return false
  }

  fileprivate var domainSortKey: String {
    DomainHost.host(item.backend.urlPrefix).lowercased()
  }

  fileprivate var sourceSortKey: String {
    AssetSource.of(meta: item.asset.meta).rawValue
  }

  fileprivate var tableName: String {
    item.asset.originalFilename ?? (item.asset.key as NSString).lastPathComponent
  }
}

/// One month of the table: the grid header's words over its rows.
struct AssetTableSection: TableRowContent {
  let model: GalleryModel
  let month: String
  let rows: [GalleryModel.Row]

  var tableRowBody: some TableRowContent<GalleryModel.Row> {
    Section {
      ForEach(rows) { row in
        AssetTableRow(model: model, row: row)
      }
    } header: {
      let count = model.monthHeaderCount(month, loaded: rows.count)
      Text(AssetTableView.monthTitle(month, count: count))
        .pinaxSectionTitle()
    }
  }
}

/// One asset's row, with the grid's drag (see `tableDragItemProvider`)
/// and the grid's context menu.
struct AssetTableRow: TableRowContent {
  let model: GalleryModel
  let row: GalleryModel.Row

  var tableRowBody: some TableRowContent<GalleryModel.Row> {
    TableRow(row)
      .itemProvider { model.tableDragItemProvider(for: row) }
      .contextMenu {
        AssetContextMenuItems(model: model, row: row)
      }
  }
}

/// Usage ▸ Images ▸ Table: the library's row, opening
/// to one row per reference.
struct UsageImageTableRow: TableRowContent {
  let model: GalleryModel
  let row: GalleryModel.Row

  var tableRowBody: some TableRowContent<GalleryModel.Row> {
    DisclosureTableRow(row, isExpanded: isExpanded) {
      ForEach(row.usageChildren ?? []) { child in
        TableRow(child)
          .contextMenu {
            UsageMenuItems(model: model, row: child)
          }
      }
    }
    .itemProvider { model.tableDragItemProvider(for: row) }
    .contextMenu {
      AssetContextMenuItems(model: model, row: row)
    }
  }

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { model.usageExpandedIDs.contains(row.id) },
      set: { expanded in
        if expanded {
          model.usageExpandedIDs.insert(row.id)
        } else {
          model.usageExpandedIDs.remove(row.id)
        }
      })
  }
}
