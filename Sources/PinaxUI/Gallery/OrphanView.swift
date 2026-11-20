import CatalogCore
import SwiftUI

/// The orphan view. It is strictly read-only:
/// no delete, no archive, no multi-select action of any kind. A click
/// selects as in the main grid, and a double-click opens Quick Look.
///
/// A `ReportHeader` — "Orphans", the candidate count and
/// any never-scanned projects in the summary, the caveat and scan-health
/// text in its Details — over the main grid's own cells:
/// `AssetGridCell` with the selection ring and the context menu, the grid's
/// gaps and inset, and the grid's column count. No paging and no rung fade:
/// the report is one list. When every project with assets has never
/// completed a scan the list says nothing, so it is not shown; when only
/// some have, candidates only in those projects wait in a collapsed group
/// under the grid.
struct OrphanView: View {
  @ObservedObject var model: GalleryModel
  /// The grid's one hovered cell (`GridHoverState`), found from
  /// the cell frames, as the library grid does.
  @State private var hover = GridHoverState()
  @State private var cellFrames: [GalleryModel.Row.ID: CGRect] = [:]
  private static let hoverSpace = "pinax.orphans.grid"

  var body: some View {
    let composed = ReportHeaderModel.compose(
      orphanCandidates: model.orphanReport?.assets.count,
      health: model.orphanHealth,
      projects: model.orphanScopeProjects,
      untracked: model.orphanReport?.untracked.count ?? 0,
      notTrackedProjects: model.orphanReport?.notTrackedProjects.count ?? 0)
    VStack(spacing: 0) {
      ReportHeader(
        title: "Orphans",
        summary: composed.header.summary,
        details: composed.header.details
      ) {
        EmptyView()
      } accessory: {
        if composed.header.offersMaintenance {
          OpenMaintenanceButton()
        }
      }
      content(composed.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func content(_ content: ReportHeaderModel.OrphanContent) -> some View {
    if let message = model.errorMessage {
      FailureStateView(message: message)
    } else {
      switch content {
      case .loading:
        ProgressView()
      case .usageUnknown(let names):
        // Usage Unknown names every project with assets (`ReportHeaderModel`).
        let slugs = model.orphanScopeProjects.filter { $0.assetCount > 0 }.map(\.slug)
        ContentUnavailableView(.usageUnknown(projects: names)) {
          UsageScanAction(
            model: model, projects: slugs,
            hasSources: !slugs.isEmpty && slugs.allSatisfy(model.sourcedProjects.contains))
        }
      case .candidates:
        if let report = model.orphanReport, !report.assets.isEmpty {
          let split = ReportHeaderModel.splitOrphans(report, health: model.orphanHealth)
          grid(
            split.scanned.map(GalleryModel.Row.init),
            notYetScanned: split.notYetScanned.map(GalleryModel.Row.init))
        } else {
          ContentUnavailableView(.noOrphanCandidates)
        }
      }
    }
  }

  /// The main grid's cell composition (`AssetGridView.grid`), minus what a
  /// one-shot report has no use for: paging, the rung fade and the drag.
  /// Candidates only in never-scanned projects sit under it in a collapsed
  /// "Not yet scanned (N)" group.
  private func grid(
    _ rows: [GalleryModel.Row], notYetScanned: [GalleryModel.Row]
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AssetGridView.rowSpacing) {
        cells(rows)
        if !notYetScanned.isEmpty {
          DisclosureGroup(isExpanded: $model.showsNotYetScannedOrphans) {
            cells(notYetScanned)
          } label: {
            Text(verbatim: "Not yet scanned (\(notYetScanned.count))")
              .pinaxSectionTitle()
              .monospacedDigit()
          }
        }
      }
      .padding(AssetGridView.gridInset / 2)
      .background(
        GeometryReader { geo in
          Color.clear.preference(key: OrphanPaneWidthKey.self, value: geo.size.width)
        })
    }
  }

  private func cells(_ rows: [GalleryModel.Row]) -> some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: AssetGridView.cellSpacing),
        count: max(1, model.gridColumns)),
      spacing: AssetGridView.rowSpacing
    ) {
      ForEach(rows) { row in
        AssetGridCell(
          row: row,
          cache: model.thumbnails,
          overlays: model.gridOverlays,
          thumbnailSizing: model.gridThumbnailSizing,
          isSelected: model.selectedIDs.contains(row.id),
          quickLook: model.quickLook,
          tier: SourceTier(columns: model.gridColumns),
          hover: hover)
          .onTapGesture { model.clickCell(row) }
          .assetContextMenu(model: model, row: row)
          .background(
            GeometryReader { geo in
              Color.clear
                .preference(key: OrphanCellWidthsKey.self, value: [row.id: geo.size.width])
                .preference(
                  key: OrphanCellFramesKey.self,
                  value: [row.id: geo.frame(in: .named(Self.hoverSpace))])
            })
      }
    }
    .coordinateSpace(name: Self.hoverSpace)
    .onPreferenceChange(OrphanCellFramesKey.self) { cellFrames = $0 }
    .onContinuousHover(coordinateSpace: .named(Self.hoverSpace)) { phase in
      switch phase {
      case let .active(point): hover.pointer(at: point, in: cellFrames)
      case .ended: hover.clear()
      }
    }
    .onChange(of: model.gridColumns) { _, _ in hover.clear() }
  }
}

/// The orphan cells' frames in the grid's own space, for the hover.
struct OrphanCellFramesKey: PreferenceKey {
  static let defaultValue: [GalleryModel.Row.ID: CGRect] = [:]
  static func reduce(
    value: inout [GalleryModel.Row.ID: CGRect], nextValue: () -> [GalleryModel.Row.ID: CGRect]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

/// The width the orphan grid lays out in — the pane `cellWidth` is given.
struct OrphanPaneWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Each orphan cell's rendered width, for the hosted test that holds it to
/// `AssetGridView.cellWidth(columns:paneWidth:)`.
struct OrphanCellWidthsKey: PreferenceKey {
  static let defaultValue: [GalleryModel.Row.ID: CGFloat] = [:]
  static func reduce(
    value: inout [GalleryModel.Row.ID: CGFloat], nextValue: () -> [GalleryModel.Row.ID: CGFloat]
  ) {
    value.merge(nextValue()) { $1 }
  }
}
