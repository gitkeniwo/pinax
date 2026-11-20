import CatalogCore
import SwiftUI

/// A restore's three moments, on whichever window started
/// it — the confirmation (file, date, what it holds, what it leaves out),
/// the error a file that will not restore gets instead, and Catalog
/// Restored with what this Mac still needs.
struct CatalogRestoreSheets: ViewModifier {
  @ObservedObject var app: PinaxAppModel
  let presenter: BackupPresenter

  func body(content: Content) -> some View {
    if let model = app.backup {
      content.modifier(Presented(app: app, model: model, presenter: presenter))
    } else {
      content
    }
  }

  private struct Presented: ViewModifier {
    let app: PinaxAppModel
    @ObservedObject var model: BackupModel
    let presenter: BackupPresenter

    func body(content: Content) -> some View {
      content
        .sheet(
          isPresented: Binding(
            get: { model.isConfirmationPresented(by: presenter) },
            set: { presented in if !presented { model.cancelRestore() } })
        ) {
          if let preview = model.pendingRestore {
            switch model.restoreStep {
            case .confirm:
              RestoreConfirmationSheet(
                preview: preview,
                cancel: { model.cancelRestore() },
                restore: { Task { await model.confirmRestore() } })
            case .offerSave:
              SaveBeforeReplacingSheet(
                model: model,
                cancel: { model.cancelRestore() },
                save: { Task { await model.saveThenReplace() } },
                replace: { Task { await model.replaceWithoutSaving() } })
            }
          }
        }
        .sheet(
          isPresented: Binding(
            get: { model.isOutcomePresented(by: presenter) },
            set: { presented in if !presented { model.dismissRestored() } })
        ) {
          if let outcome = model.restoredOutcome {
            CatalogRestoredSheet(
              outcome: outcome,
              openBackends: { slug in
                model.dismissRestored()
                app.showBackendSettings(slug: slug)
              },
              locate: { slug in
                model.dismissRestored()
                app.showProjectSettings(slug: slug)
              },
              done: { model.dismissRestored() })
          }
        }
        .alert(
          "Can't Restore Backup",
          isPresented: Binding(
            get: { model.isErrorPresented(by: presenter) },
            set: { presented in if !presented { model.dismissRestoreError() } })
        ) {
          Button("OK") { model.dismissRestoreError() }
        } message: {
          Text(model.restoreError ?? "")
        }
    }
  }
}

extension View {
  func catalogRestoreSheets(_ app: PinaxAppModel, presenter: BackupPresenter) -> some View {
    modifier(CatalogRestoreSheets(app: app, presenter: presenter))
  }
}

/// "Restore Catalog from Backup?" — the canvas's row 8 confirmation; on a
/// catalog with anything in it, "Replace Catalog with Backup?".
struct RestoreConfirmationSheet: View {
  let preview: RestorePreview
  let cancel: () -> Void
  let restore: () -> Void

  var title: String {
    preview.replacing == nil ? "Restore Catalog from Backup?" : "Replace Catalog with Backup?"
  }

  /// "pinax-backup-2026-10-08.json, saved 8 Oct 2026 at 21:14. …"
  var summary: String {
    let saved =
      "\(preview.fileName), saved \(PinaxFormat.date(preview.generatedAt, style: .dayTime)). "
    guard let current = preview.replacing else {
      return saved + "This catalog is empty, so nothing is replaced."
    }
    return saved + "This replaces everything in the current catalog (\(Self.briefly(current))); "
      + "it can't be undone."
  }

  var restoreTitle: String { preview.replacing == nil ? "Restore" : "Replace…" }

  /// "83 assets, 1 project, 1 backend".
  static func briefly(_ counts: CatalogTableCounts) -> String {
    [
      PinaxFormat.count(counts.assets, singular: "asset"),
      PinaxFormat.count(counts.projects, singular: "project"),
      PinaxFormat.count(counts.backends, singular: "backend"),
    ].joined(separator: ", ")
  }

  /// The rows: label and value, in the canvas's order.
  var rows: [(label: String, value: String)] {
    let counts = preview.counts
    return [
      ("Assets", counts.assets.formatted()),
      ("Projects", Self.listed(counts.projects, preview.projectSlugs)),
      ("Backends", Self.listed(counts.backends, preview.backendSlugs)),
      (
        "Favorites, labels, tags",
        "\(counts.favorites.formatted()) · \(counts.assetLabels.formatted()) · \(counts.tags.formatted())"
      ),
      (
        "Scans and usage",
        "\(PinaxFormat.count(counts.scans, singular: "scan")) · "
          + PinaxFormat.count(counts.usages, singular: "reference")
      ),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text(title)
        .pinaxTitle()
      Text(summary)
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
      Form {
        Section {
          ForEach(rows, id: \.label) { row in
            LabeledContent(row.label) {
              Text(row.value)
                .monospacedDigit()
            }
          }
        } footer: {
          Text("Not in the backup: credentials (Keychain) and app preferences.")
            .pinaxSecondary()
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        if preview.replacing == nil {
          Button(restoreTitle, action: restore)
            .keyboardShortcut(.defaultAction)
        } else {
          Button(restoreTitle, role: .destructive, action: restore)
        }
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: DesignMetrics.backupSheet.width)
  }

  /// "1 · astro", "3 · a, b, c".
  static func listed(_ count: Int, _ slugs: [String]) -> String {
    slugs.isEmpty ? count.formatted() : "\(count.formatted()) · \(slugs.joined(separator: ", "))"
  }
}

/// The second question before a replacement: save the catalog about to be
/// replaced, or replace it without a backup.
struct SaveBeforeReplacingSheet: View {
  @ObservedObject var model: BackupModel
  let cancel: () -> Void
  let save: () -> Void
  let replace: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text("Save the Current Catalog First?")
        .pinaxTitle()
      Text(
        "Save a backup of the catalog you are replacing, so you can restore it if you need it."
      )
      .pinaxSecondary()
      .fixedSize(horizontal: false, vertical: true)
      if let error = model.saveBeforeReplacingError {
        Text(error)
          .pinaxBody()
          .textSelection(.enabled)
      }
      HStack {
        if model.isCreating || model.isRestoring {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        Button("Replace Without Saving", role: .destructive, action: replace)
        Button("Save and Replace…", action: save)
          .keyboardShortcut(.defaultAction)
      }
      .disabled(model.isCreating || model.isRestoring)
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: DesignMetrics.backupSheet.width)
  }
}

/// "Catalog Restored": how much came back, and one row with one button per
/// thing this Mac still needs.
struct CatalogRestoredSheet: View {
  let outcome: RestoreOutcome
  let openBackends: (String) -> Void
  let locate: (String) -> Void
  let done: () -> Void

  /// "83 assets, 1 project, 1 backend."
  var summary: String { RestoreConfirmationSheet.briefly(outcome.counts) + "." }

  struct FollowUp: Identifiable, Equatable {
    enum Action: Equatable {
      case openBackends(String)
      case locate(String)
    }

    let id: String
    let title: String
    let detail: String
    let buttonTitle: String
    let action: Action
  }

  var followUps: [FollowUp] {
    outcome.followUps.backendsWithoutCredentials.map { slug in
      FollowUp(
        id: "backend-\(slug)",
        title: "Backend \(slug) has no credentials on this Mac",
        detail: "Uploads and remote checks need them. Browsing works now.",
        buttonTitle: "Open Backends", action: .openBackends(slug))
    }
      + outcome.followUps.projectsWithMissingSources.map { project in
        FollowUp(
          id: "project-\(project.projectSlug)",
          title: "\(project.projectSlug): source folder not found",
          detail: project.paths.joined(separator: "\n"),
          buttonTitle: "Locate…", action: .locate(project.projectSlug))
      }
  }

  func perform(_ action: FollowUp.Action) {
    switch action {
    case .openBackends(let slug): openBackends(slug)
    case .locate(let slug): locate(slug)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text("Catalog Restored")
        .pinaxTitle()
      Text(summary)
        .pinaxSecondary()
      if !followUps.isEmpty {
        Form {
          ForEach(followUps) { item in
            FollowUpRow(item: item, perform: perform)
          }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Done", action: done)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: DesignMetrics.backupSheet.width)
  }

  private struct FollowUpRow: View {
    let item: FollowUp
    let perform: (FollowUp.Action) -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
        Image(systemName: "exclamationmark.triangle")
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs / 2) {
          Text(item.title)
            .pinaxBody()
          Text(item.detail)
            .pinaxSecondary()
            .textSelection(.enabled)
        }
        Spacer()
        Button(item.buttonTitle) {
          perform(item.action)
          openSettings()
        }
      }
    }
  }
}

/// Settings ▸ Maintenance ▸ Backup: Save Backup…, then Restore….
struct BackupSection: View {
  @ObservedObject var model: BackupModel

  var restoreDisabled: Bool { !model.canRestore }

  /// The Restore button's action: the one restore every entry calls.
  var restoreAction: () async -> Void {
    { [model] in await model.beginRestore(presenter: .settings) }
  }

  /// Two rows, each with what it does under its name, a
  /// spinner beside the running one, the last result under them.
  var body: some View {
    SettingsSection("Backup") {
      SettingsGroup {
        SettingsRow("Back up the catalog", subtitle: "Saves a copy to a file you choose.") {
          if model.isCreating { ProgressView().controlSize(.small) }
          Button("Save Backup…") { Task { await model.create() } }
            .disabled(model.isCreating)
        }
        SettingsRowDivider()
        SettingsRow(
          "Restore from a backup", subtitle: "Replaces the current catalog. Pinax asks before it does."
        ) {
          if model.isRestoring { ProgressView().controlSize(.small) }
          Button("Restore…") { Task { await restoreAction() } }
            .disabled(restoreDisabled)
        }
        if let notice = model.notice {
          SettingsRowDivider()
          SettingsRow(notice)
            .textSelection(.enabled)
        }
      }
    }
    .task { await model.refreshCatalogState() }
  }
}
