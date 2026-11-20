import SwiftUI

/// The report surfaces' shared header: one bar of
/// `sectionHeader.height` — title, summary, the report's own controls on the
/// right — on the bar material, then the report's explanation under it.
/// The explanation is not tucked into a popover; anything over
/// two lines folds into a system `DisclosureGroup` titled "Details",
/// collapsed by default, with the report's action beside it.
struct ReportHeader<Controls: View, Accessory: View>: View {
  let title: String
  let summary: String
  let details: [ReportNote]
  @ViewBuilder var controls: () -> Controls
  /// Beside the explanation, e.g. Open Maintenance….
  @ViewBuilder var accessory: () -> Accessory
  /// Beside the summary: Externals' ⓘ, in place of
  /// its Details. Type-erased so the header keeps its two parameters.
  var info: AnyView?

  @State private var detailsExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
        Text(title)
          .pinaxTitle()
        Text(summary)
          .pinaxSecondary()
          .monospacedDigit()
          .lineLimit(1)
          .textSelection(.enabled)
        if let info { info }
        Spacer(minLength: DesignMetrics.spacing.s)
        controls()
      }
      .padding(.horizontal, DesignMetrics.spacing.l)
      .frame(height: DesignMetrics.sectionHeader.height)
      .background(
        GeometryReader { geo in
          Color.clear.preference(key: ReportHeaderBarHeightKey.self, value: [title: geo.size.height])
        })
      if !details.isEmpty {
        Divider()
        HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
          DisclosureGroup("Details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: DesignMetrics.spacing.s) {
              ForEach(Array(details.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
                  if let heading = note.heading {
                    Text(heading)
                      .pinaxSectionTitle()
                  }
                  ForEach(note.lines, id: \.self) { line in
                    Text(line)
                      .pinaxSecondary()
                      .fixedSize(horizontal: false, vertical: true)
                      .textSelection(.enabled)
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DesignMetrics.spacing.xs)
          }
          .pinaxSecondary()
          accessory()
        }
        .padding(.horizontal, DesignMetrics.spacing.l)
        .padding(.vertical, DesignMetrics.spacing.s)
      }
      Divider()
    }
    .background(.bar)
  }
}

extension ReportHeader where Accessory == EmptyView {
  init(
    title: String, summary: String, details: [ReportNote],
    @ViewBuilder controls: @escaping () -> Controls
  ) {
    self.init(
      title: title, summary: summary, details: details, controls: controls,
      accessory: { EmptyView() })
  }

  /// A header with an ⓘ beside its summary and no Details row.
  init<Info: View>(
    title: String, summary: String,
    @ViewBuilder controls: @escaping () -> Controls,
    @ViewBuilder info: () -> Info
  ) {
    self.init(
      title: title, summary: summary, details: [], controls: controls,
      accessory: { EmptyView() }, info: AnyView(info()))
  }
}

/// The header bar's rendered height by report title, for the hosted tests
/// that hold every report's bar to `sectionHeader.height`.
struct ReportHeaderBarHeightKey: PreferenceKey {
  static let defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue()) { $1 }
  }
}

/// A report's way to the scans it is missing — the
/// Settings window, where Maintenance runs usage syncs.
struct OpenMaintenanceButton: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Open Maintenance…") { openSettings() }
      .controlSize(.small)
  }
}

/// A report's empty-state action. With sources everywhere it
/// names, Scan Now — the app's one scan, through the closure the shell
/// installs. Otherwise the way to add them: Settings ▸ Projects with the
/// first project still missing a source selected.
struct UsageScanAction: View {
  @ObservedObject var model: GalleryModel
  let projects: [String]
  let hasSources: Bool

  var body: some View {
    if hasSources {
      ScanNowButton(action: { model.onScanNow?(projects) })
    } else {
      ProjectSettingsLinkButton(
        title: projects.count == 1 ? "Add Source…" : "Open Project Settings…",
        action: {
          if let slug = projects.first(where: { !model.sourcedProjects.contains($0) }) {
            model.onOpenProjectSettings?(slug)
          }
        })
    }
  }
}
