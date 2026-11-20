import CatalogCore
import SwiftUI

// The menu bar panel's statistics card and Library page. Both only draw a
// `MenuBarLibrary`.

/// The whole card is one plain `Button`: three numbers over the 14 bars,
/// and a column on the right with a › (no count). No standard control draws a
/// framed stat card; this is layout only.
struct MenuBarStatsCard: View {
  let library: MenuBarLibrary
  /// What one bar covers: Settings ▸ Appearance ▸ Menu Bar Chart.
  let unit: MenuBarChartUnit
  /// Told the card's frame in the panel: the panel draws the card's
  /// platter itself, so it can grow into the Library page.
  var place: (CGRect) -> Void = { _ in }
  let open: () -> Void
  @State private var hovered = false
  /// The contents fade first as the card opens into the Library page.
  @Environment(\.menuBarCardFade) private var fade

  var body: some View {
    let chart = library.chart(unit)
    Button(action: open) {
      HStack(spacing: DesignMetrics.spacing.none) {
        VStack(spacing: DesignMetrics.spacing.none) {
          HStack(spacing: DesignMetrics.spacing.none) {
            cell(library.images.formatted(), "images")
            hairline
            cell(PinaxFormat.fileSize(library.bytes), "stored")
            hairline
            cell(chart.current.formatted(), unit.current)
          }
          MenuBarPalette.cardBorder.frame(height: 1)
          MenuBarUploadBars(
            bars: chart.bars, height: DesignMetrics.menuBarLibrary.cardBarsHeight,
            spacing: DesignMetrics.menuBarLibrary.barSpacing)
            .padding(.horizontal, DesignMetrics.menuBarLibrary.cellHorizontalPadding)
            .padding(.top, DesignMetrics.menuBarLibrary.cardBarsTop)
            .padding(.bottom, DesignMetrics.menuBarLibrary.cardBarsBottom)
        }
        hairline
        Image(systemName: "chevron.right")
          .imageScale(.small)
          .foregroundStyle(hovered ? .primary : .secondary)
          .frame(width: DesignMetrics.menuBarLibrary.chevronColumnWidth)
          .frame(maxHeight: .infinity)
      }
      .opacity(fade)
      // The card is as tall as its contents; the › column fills that
      // height and no more (the panel would otherwise stretch it).
      .fixedSize(horizontal: false, vertical: true)
      .background(
        hovered ? MenuBarPalette.cardHover : .clear,
        in: MenuBarPalette.cardShape)
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named(PinaxMenuBarContent.space))
      } action: { place($0) }
      .contentShape(MenuBarPalette.cardShape)
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(library.accessibilityLabel(unit))
    .accessibilityAddTraits(.isButton)
  }

  private var hairline: some View { MenuBarPalette.cardBorder.frame(width: 1) }

  private func cell(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: DesignMetrics.menuBarLibrary.labelSpacing) {
      Text(value).pinaxBody().fontWeight(.semibold).monospacedDigit().lineLimit(1)
      Text(label).pinaxSecondary().lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, DesignMetrics.menuBarLibrary.cellHorizontalPadding)
    .padding(.vertical, DesignMetrics.menuBarLibrary.cellVerticalPadding)
  }
}

/// One rounded bar per period, oldest on the left; the current one in the
/// canvas's green. A bar with no uploads is a short stub.
struct MenuBarUploadBars: View {
  let bars: [MenuBarLibrary.Bar]
  let height: CGFloat
  let spacing: CGFloat

  /// A bar's height: its share of the tallest, never under the stub.
  static func barHeight(count: Int, tallest: Int, height: CGFloat) -> CGFloat {
    max(
      DesignMetrics.menuBarLibrary.barMinHeight,
      height * CGFloat(count) / CGFloat(max(1, tallest)))
  }

  var body: some View {
    let tallest = bars.map(\.count).max() ?? 0
    HStack(alignment: .bottom, spacing: spacing) {
      ForEach(bars, id: \.start) { bar in
        RoundedRectangle(cornerRadius: DesignMetrics.menuBarLibrary.barRadius)
          .fill(bar.isCurrent ? MenuBarPalette.accent : MenuBarPalette.bar)
          .frame(height: Self.barHeight(count: bar.count, tallest: tallest, height: height))
          .frame(maxWidth: .infinity)
      }
    }
    .frame(height: height, alignment: .bottom)
    .accessibilityHidden(true)
  }
}

/// The Library page: replaces the home page in the same panel, at the
/// home page's height. The header stays at the top and the footer at the
/// bottom; what lies between scrolls when it does not fit (the scroller
/// hidden), and sits at the top when it does, the space left above the
/// footer.
struct MenuBarLibraryPage: View {
  @ObservedObject var app: PinaxAppModel
  @ObservedObject var preferences: PreferencesStore
  /// Holds the page's own Day / Week / Month.
  @ObservedObject var panel: MenuBarPanelModel
  let library: MenuBarLibrary
  let back: () -> Void
  let openGallery: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.menuBarLibrary.pageSpacing) {
      header
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: DesignMetrics.menuBarLibrary.pageSpacing) {
          HStack(
            alignment: .firstTextBaseline, spacing: DesignMetrics.menuBarLibrary.bigNumberSpacing
          ) {
            bigNumber(library.images.formatted(), "images in catalog")
            bigNumber(PinaxFormat.fileSize(library.bytes), library.storedLine)
          }
          let segments = library.segments(preferences.menuBarStorageSplit)
          if !segments.isEmpty {
            storageBar(segments)
          }
          uploads
          if !library.attention.isEmpty {
            attention
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      Divider()
      footer
    }
  }

  private var header: some View {
    HStack(spacing: DesignMetrics.spacing.xs) {
      Button(action: back) {
        HStack(spacing: DesignMetrics.spacing.xs) {
          Image(systemName: "chevron.left").foregroundStyle(.secondary)
          Text("Library").pinaxBody().bold()
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Back")
      Spacer()
      ProjectMenu(app: app, preferences: preferences)
    }
  }

  private var footer: some View {
    HStack {
      if let scanned = library.scanned {
        Text(scanned).pinaxSecondary()
      }
      Spacer()
      Button("Open Overview ↗") {
        app.gallery?.select(.overview, in: .reports)
        openGallery()
      }
      .buttonStyle(.link)
      .disabled(app.gallery == nil)
    }
  }

  private func bigNumber(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      Text(value).pinaxTitle().monospacedDigit()
      Text(label).pinaxSecondary()
    }
  }

  private func storageBar(_ segments: [MenuBarLibrary.Segment]) -> some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      GeometryReader { proxy in
        let gaps = CGFloat(segments.count - 1) * DesignMetrics.menuBarLibrary.backendGap
        HStack(spacing: DesignMetrics.menuBarLibrary.backendGap) {
          ForEach(Array(segments.enumerated()), id: \.offset) { index, backend in
            Rectangle()
              .fill(MenuBarPalette.backend(index))
              .frame(width: max(0, (proxy.size.width - gaps) * backend.fraction))
          }
        }
      }
      .frame(height: DesignMetrics.menuBarLibrary.backendBarHeight)
      .clipShape(Capsule())
      .accessibilityHidden(true)
      HStack(spacing: DesignMetrics.menuBarLibrary.legendSpacing) {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, backend in
          HStack(spacing: DesignMetrics.menuBarLibrary.legendSwatchSpacing) {
            RoundedRectangle(cornerRadius: DesignMetrics.menuBarLibrary.barRadius)
              .fill(MenuBarPalette.backend(index))
              .frame(width: DesignMetrics.menuBarLibrary.legendSwatch, height: DesignMetrics.menuBarLibrary.legendSwatch)
            Text(backend.legend).pinaxSecondary().monospacedDigit().lineLimit(1)
          }
        }
      }
    }
  }

  private var uploads: some View {
    let chart = library.chart(panel.libraryUnit)
    return VStack(alignment: .leading, spacing: DesignMetrics.spacing.s) {
      HStack {
        Text(chart.title).pinaxSecondary().fontWeight(.semibold)
        Spacer()
        Text(library.uploadsLine(chart.unit)).pinaxSecondary().monospacedDigit()
      }
      Picker("Each Bar", selection: $panel.libraryUnit) {
        ForEach(MenuBarChartUnit.libraryUnits) { unit in
          Text(unit.name).tag(unit)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      MenuBarUploadBars(
        bars: chart.bars, height: DesignMetrics.menuBarLibrary.pageBarsHeight,
        spacing: DesignMetrics.menuBarLibrary.pageBarSpacing)
        .accessibilityElement()
        .accessibilityLabel("Uploads per \(chart.unit.rawValue) over the last 14 \(chart.unit.rawValue)s")
      HStack {
        Text(chart.firstLabel)
        Spacer()
        Text(chart.lastLabel)
      }
      .pinaxSecondary()
    }
    .padding(DesignMetrics.menuBarLibrary.cellHorizontalPadding)
    .menuBarCard()
  }

  private var attention: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.menuBarLibrary.listSpacing) {
      Text("NEEDS ATTENTION").pinaxSecondary().fontWeight(.semibold)
        .padding(.bottom, DesignMetrics.spacing.xs)
      ForEach(library.attention, id: \.action) { row in
        HStack(spacing: DesignMetrics.menuBarLibrary.rowSpacing) {
          Circle()
            .fill(row.isWarning ? MenuBarPalette.attention : MenuBarPalette.scanDot)
            .frame(width: DesignMetrics.menuBarLibrary.rowDot, height: DesignMetrics.menuBarLibrary.rowDot)
          Text(row.text).pinaxBody()
          Spacer()
          action(for: row)
        }
        .frame(height: DesignMetrics.menuBarLibrary.rowHeight)
      }
    }
  }

  @ViewBuilder private func action(for row: MenuBarLibrary.Attention) -> some View {
    switch row {
    case .failedUploads:
      Button(row.action) {
        panel.dismiss()
        Task { await app.showDropZoneFromMenuBar() }
      }
      .disabled(app.dropZone == nil)
      .buttonStyle(.bordered).controlSize(.small)
    case .orphanCandidates:
      Button(row.action) {
        app.gallery?.openOverview(.orphans)
        openGallery()
      }
      .disabled(app.gallery == nil)
      .buttonStyle(.bordered).controlSize(.small)
    case .lastScan:
      if let usageSync = app.usageSync {
        MenuBarScanButton(usageSync: usageSync, title: row.action) {
          Task { if await app.scanFromMenuBar() { openGallery() } }
        }
      }
    }
  }
}

/// Scan, or a spinner in its place while any scan runs.
private struct MenuBarScanButton: View {
  @ObservedObject var usageSync: UsageSyncModel
  let title: String
  let scan: () -> Void

  var body: some View {
    if usageSync.isSyncing {
      ProgressView().controlSize(.small)
        .accessibilityLabel("Scanning")
    } else {
      Button(title, action: scan)
        .buttonStyle(.bordered).controlSize(.small)
    }
  }
}

extension View {
  /// The statistics and uploads cards' translucent fill and frame. The
  /// whole card tints under the pointer; no part of it draws its own
  /// highlight (a separate › column fill read as a rounded shadow).
  func menuBarCard(hovered: Bool = false) -> some View {
    let shape = MenuBarPalette.cardShape
    return background(
      ZStack {
        shape.fill(hovered ? MenuBarPalette.cardHover : MenuBarPalette.card)
        shape.strokeBorder(MenuBarPalette.cardBorder)
      })
  }
}
