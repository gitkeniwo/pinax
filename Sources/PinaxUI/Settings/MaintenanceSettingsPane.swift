import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

struct MaintenanceSettingsPane: View {
  @ObservedObject var app: PinaxAppModel

  var body: some View {
    if let model = app.maintenance {
      MaintenanceSettingsContent(model: model, backup: app.backup, usageSync: app.usageSync)
        .catalogRestoreSheets(app, presenter: .settings)
    } else {
      Text("The catalog is not open yet.")
        .pinaxSecondary()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// The doctor's verdict on a card
/// of its own, then Checks (one row per check), Backup, Usage sync.
///
/// No Re-add… beside the usage-membership warning: neither CatalogCore nor
/// a model has a call that repairs memberships (only one asset's
/// `AssetCatalog.addToProject`); the button belongs here once one exists.
struct MaintenanceSettingsContent: View {
  @ObservedObject var model: MaintenanceModel
  let backup: BackupModel?
  let usageSync: UsageSyncModel?
  /// When the shown report was taken; the model keeps only the report.
  @State private var checkedAt: Date?

  init(
    model: MaintenanceModel, backup: BackupModel? = nil, usageSync: UsageSyncModel? = nil
  ) {
    self.model = model
    self.backup = backup
    self.usageSync = usageSync
  }

  var body: some View {
    Group {
      if let report = model.report {
        SettingsPage {
          statusCard(report)
          SettingsSection("Checks") {
            SettingsGroup {
              ForEach(Array(report.checks.enumerated()), id: \.offset) { index, check in
                if index > 0 { SettingsRowDivider() }
                DoctorCheckRow(check: check, usageSync: usageSync)
                  .accessibilityIdentifier("doctor-check-\(index)")
              }
            }
          }
          if let backup {
            BackupSection(model: backup)
          } else {
            SettingsSection("Backup") {
              SettingsGroup { SettingsRow("The catalog is not open yet.") }
            }
          }
          SettingsSection("Usage sync") {
            SettingsGroup {
              if let usageSync {
                UsageSyncControls(model: usageSync)
              } else {
                SettingsRow("The catalog is not open yet.")
              }
            }
          }
        }
      } else if let loadError = model.loadError {
        Text(loadError)
          .pinaxBody()
          .pinaxError()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task { await check() }
    .task { await usageSync?.loadProjects() }
  }

  private func check() async {
    await model.load()
    checkedAt = Date()
  }

  private func statusCard(_ report: DoctorReport) -> some View {
    SettingsGroup {
      HStack(spacing: Metrics.rowSpacing) {
        DoctorStatusSymbol(status: Self.overallStatus(report), size: Metrics.statusCardSymbolSize)
        VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
          Text(Self.summary(for: report))
            .pinaxSettingsHeaderTitle()
            .accessibilityIdentifier("doctor-summary")
          if let checkedAt {
            TimelineView(.periodic(from: checkedAt, by: 60)) { context in
              Text(Self.checkedText(at: checkedAt, now: context.date))
                .pinaxSettingsRowSubtitle()
            }
          } else {
            // Holds the line's height before the first check lands, so the
            // verdict above does not jump up when the time appears.
            Text(Self.checkedText(at: .now, now: .now))
              .pinaxSettingsRowSubtitle()
              .hidden()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button("Run Again") { Task { await check() } }
          .disabled(model.isLoading)
      }
      .padding(Metrics.statusCardPadding)
    }
  }

  /// "1 warning, nothing failed", "No warnings, 2 failed".
  static func summary(for report: DoctorReport) -> String {
    let failures = report.checks.count { $0.status == .failure }
    let warnings = report.checks.count { $0.status == .warning }
    let warningPart = warnings == 0 ? "No warnings" : "\(warnings) \(warnings == 1 ? "warning" : "warnings")"
    let failurePart = failures == 0 ? "nothing failed" : "\(failures) failed"
    return "\(warningPart), \(failurePart)"
  }

  /// The card's symbol: the worst a check came to; information alone is
  /// still a pass.
  static func overallStatus(_ report: DoctorReport) -> DoctorStatus {
    let statuses = Set(report.checks.map(\.status))
    if statuses.contains(.failure) { return .failure }
    if statuses.contains(.warning) { return .warning }
    return .pass
  }

  /// "Checked just now" for the first minute, then "Checked 5 minutes ago".
  static func checkedText(at date: Date, now: Date, locale: Locale = .current) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return "Checked just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    return "Checked \(formatter.localizedString(for: date, relativeTo: now))"
  }
}

private struct UsageSyncControls: View {
  @ObservedObject var model: UsageSyncModel

  var body: some View {
    Group {
      if let projects = model.projects, !projects.isEmpty {
        SettingsRow("Project") {
          SettingsMenuPicker("Project", selection: $model.selectedProject) {
            ForEach(projects, id: \.self) { project in
              Text(project).tag(Optional(project))
            }
          } label: {
            Text(model.selectedProject ?? "")
          }
        }
        SettingsRowDivider()
        SettingsRow(
          "Usage document",
          subtitle: model.isSyncing
            ? "Syncing may take a few minutes."
            : "Import usage recorded outside Pinax for this project."
        ) {
          if model.isSyncing { ProgressView().controlSize(.small) }
          Button("Choose…") { Task { await model.chooseAndSync() } }
            .disabled(model.isSyncing)
        }
      } else if model.projects?.isEmpty == true {
        SettingsRow("Add a project before syncing usage.")
      }
      if let result = model.result {
        SettingsRowDivider()
        SettingsRow("Scan ID: \(result.scanID)", subtitle: "Found references: \(result.foundCount)")
          .monospacedDigit()
          .textSelection(.enabled)
      }
      if let errorMessage = model.errorMessage {
        SettingsRowDivider()
        Text(errorMessage)
          .pinaxBody()
          .pinaxError()
          .textSelection(.enabled)
          .padding(.vertical, Metrics.rowVerticalPadding)
          .padding(.horizontal, Metrics.rowHorizontalPadding)
          .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
      }
    }
    .usageEmptyScanConfirmation(model, presenter: .settings)
  }
}

/// A check's status as a symbol in its status colour, the glyph inside in
/// the status glyph colour.
struct DoctorStatusSymbol: View {
  let status: DoctorStatus
  let size: CGFloat

  var body: some View {
    Image(systemName: symbol)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .symbolRenderingMode(.palette)
      .foregroundStyle(PinaxPalette.statusGlyph, color)
      .frame(width: size, height: size)
      .accessibilityLabel(label)
  }

  private var symbol: String {
    switch status {
    case .pass: return "checkmark.circle.fill"
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .failure: return "xmark.octagon.fill"
    }
  }

  private var color: Color {
    switch status {
    case .pass: return PinaxPalette.Status.pass
    case .info: return PinaxPalette.Status.info
    case .warning: return PinaxPalette.Status.warning
    case .failure: return PinaxPalette.Status.failure
    }
  }

  private var label: String {
    switch status {
    case .pass: return "Passed"
    case .info: return "Information"
    case .warning: return "Warning"
    case .failure: return "Failed"
    }
  }
}

/// One Doctor check: its status symbol, its name in words, and its detail
/// under it — one line when it passed, in full otherwise. The check's own
/// id — what `pinax doctor` prints — is the row's help tag. The words are a
/// UI mapping only: `DoctorCheck.name`, the CLI's output and the
/// accessibility identifier are unchanged.
struct DoctorCheckRow: View {
  let check: DoctorCheck
  let usageSync: UsageSyncModel?

  /// The row's help tag: the check's id.
  var helpTag: String { check.name }

  var body: some View {
    HStack(alignment: .top, spacing: Metrics.rowSpacing) {
      DoctorStatusSymbol(status: check.status, size: Metrics.checkSymbolSize)
      VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
        Text(Self.title(check.name))
          .textSelection(.enabled)
        if let unscanned = Self.neverScannedProjects(check) {
          ForEach(unscanned, id: \.self) { slug in
            HStack(alignment: .firstTextBaseline) {
              Text("\(slug) · never scanned")
                .pinaxSettingsRowSubtitle()
                .textSelection(.enabled)
              if let usageSync {
                Button("Choose Usage Document…") {
                  usageSync.selectedProject = slug
                  Task { await usageSync.chooseAndSync() }
                }
                .controlSize(.small)
                .disabled(usageSync.isSyncing)
              }
            }
          }
        } else {
          Text(Self.detail(check))
            .pinaxSettingsRowSubtitle()
            .lineLimit(check.status == .pass ? 1 : nil)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, Metrics.rowVerticalPadding)
    .padding(.horizontal, Metrics.rowHorizontalPadding)
    .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
    .help(helpTag)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(check.name): \(check.detail)")
  }

  /// The detail as shown: the database's path shortened with `~`.
  static func detail(_ check: DoctorCheck) -> String {
    guard check.name == "database-location" else { return check.detail }
    return (check.detail as NSString).abbreviatingWithTildeInPath
  }

  /// "database-location" → "Database location".
  static func title(_ name: String) -> String {
    let words = name.split(separator: "-").joined(separator: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// The usage-scans warning's detail is the unscanned projects' slugs, comma
  /// separated (CatalogCore). When every part is a slug, each is its own
  /// "never scanned" line; any other detail is shown as written.
  static func neverScannedProjects(_ check: DoctorCheck) -> [String]? {
    guard check.name == "usage-scans", check.status == .warning else { return nil }
    let slugs = check.detail.components(separatedBy: ", ")
    let slugCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
    let isSlug = { (part: String) in
      !part.isEmpty && part.first != "-" && part.allSatisfy(slugCharacters.contains)
    }
    guard slugs.allSatisfy(isSlug) else { return nil }
    return slugs
  }
}
