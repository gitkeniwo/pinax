import AppKit
import CatalogCore
import SwiftUI

/// Per-project backend and key prefix. The list shows every project
/// with its name, slug, key prefix, and backend; the editor below writes
/// through `CatalogConfiguration` — and only on an explicit commit (Set, or a
/// picker choice), never as a side effect of being displayed.
struct ProjectsSettingsPane: View {
  /// The pane's model exists only once the catalog has opened; this shell
  /// observes the app so the tab's content appears when it does — and says
  /// why it hasn't when it doesn't.
  @ObservedObject var app: PinaxAppModel

  var body: some View {
    if let model = app.projectSettings {
      ProjectsSettingsContent(model: model)
        .usageEmptyScanConfirmation(app.usageSync, presenter: .settings)
    } else {
      Text("The catalog is not open yet.")
        .pinaxSecondary()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// Settings ▸ Projects: the projects in the list
/// column — each with its source count, + at the foot — and the selected
/// one's page beside it. Nothing removes a project, so there is no −.
struct ProjectsSettingsContent: View {
  @ObservedObject var model: ProjectSettingsModel
  @State private var selectedSlug: String?

  var body: some View {
    Group {
      if let snapshot = model.snapshot {
        HStack(spacing: DesignMetrics.spacing.none) {
          SettingsListColumn(
            icon: .projects,
            rows: snapshot.rows.map {
              .init(id: $0.slug, name: $0.name, subtitle: Self.sourceCount($0.sources.count))
            },
            selection: listSelection(snapshot),
            // Without a backend, + is off and its help says why.
            addLabel: snapshot.backendSlugs.isEmpty
              ? ProjectSettingsModel.backendRequiredMessage : "Add project",
            removeLabel: "Remove project",
            canAdd: !snapshot.backendSlugs.isEmpty,
            onAdd: { model.beginAddition() }, onRemove: nil)
          if snapshot.rows.isEmpty {
            ContentUnavailableView(.noProjects) {
              Button("Add Project…") { model.beginAddition() }
                .disabled(snapshot.backendSlugs.isEmpty)
              if snapshot.backendSlugs.isEmpty {
                Text(ProjectSettingsModel.backendRequiredMessage)
                  .pinaxSettingsRowSubtitle()
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            editor(snapshot)
          }
        }
      } else {
        // The catalog opened but the read failed — show that failure, not a
        // generic "not open yet".
        if let saveError = model.saveError {
          Text(saveError)
            .pinaxBody()
            .pinaxError()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Text("The catalog is not open yet.")
            .pinaxSecondary()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    // Without this, the start-time load is the only one, and the empty
    // state's own advice ("create a project with the CLI") dead-ends until
    // relaunch. Re-reading on every appearance is a pure read — display may
    // read but never write — and each visit to the tab picks up CLI-side
    // project changes.
    .task {
      model.load()
      takeRequestedSlug()
    }
    // Add Source… / Open Project Settings… on a report.
    .onChange(of: model.requestedSlug) { takeRequestedSlug() }
    .sheet(
      isPresented: Binding(
        get: { model.isAdditionPresented(by: .settings) },
        set: { presented in if !presented { model.cancelAddition() } })
    ) {
      AddProjectSheet(
        model: model,
        cancel: { model.cancelAddition() },
        submit: { Task { await model.submitAddition() } })
    }
  }

  /// "1 source", "2 sources" (`.li .sub`).
  static func sourceCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "source" : "sources")"
  }

  /// The project shown: the one picked, else the first, so the list marks
  /// the row the page is about.
  private func shownRow(_ snapshot: ProjectSettingsSnapshot) -> ProjectSettingsRow? {
    snapshot.rows.first { $0.slug == selectedSlug } ?? snapshot.rows.first
  }

  private func listSelection(_ snapshot: ProjectSettingsSnapshot) -> Binding<String?> {
    Binding(
      get: { shownRow(snapshot)?.slug },
      set: { selectedSlug = $0 })
  }

  private func takeRequestedSlug() {
    guard let slug = model.requestedSlug else { return }
    selectedSlug = slug
    model.requestedSlug = nil
  }

  @ViewBuilder
  private func editor(_ snapshot: ProjectSettingsSnapshot) -> some View {
    if let row = shownRow(snapshot) {
      ProjectEditorView(row: row, backendSlugs: snapshot.backendSlugs, model: model)
        // Identity covers the stored prefix and template too: a committed,
        // normalized write rebuilds the editor so the fields show the row as
        // stored, without needing change-triggered state surgery.
        .id("\(row.slug)|\(row.keyPrefix)|\(row.keyTemplate ?? "")")
    } else {
      EmptyView()
    }
  }
}

struct AddProjectSheet: View {
  @ObservedObject var model: ProjectSettingsModel
  let cancel: () -> Void
  let submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Project")
        .pinaxTitle()
      Form {
        TextField("Slug", text: draftBinding(\.slug))
        TextField("Name", text: draftBinding(\.name))
        TextField("Key prefix", text: draftBinding(\.keyPrefix))
        Picker("Backend", selection: draftBinding(\.backendSlug)) {
          ForEach(model.snapshot?.backendSlugs ?? [], id: \.self) { slug in
            Text(slug).tag(slug)
          }
        }
      }
      if let saveError = model.saveError {
        Text(saveError)
          .pinaxBody()
          .pinaxError()
      }
      HStack {
        Spacer()
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        Button("Create", action: submit)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSubmitAddition || model.isAddingProject)
      }
    }
    .padding(20)
    .frame(width: 400)
    .disabled(model.isAddingProject)
  }

  private func draftBinding(
    _ keyPath: WritableKeyPath<NewProjectDraft, String>
  ) -> Binding<String> {
    Binding(
      get: { model.additionDraft?[keyPath: keyPath] ?? "" },
      set: { value in
        model.updateAdditionDraft { $0[keyPath: keyPath] = value }
      })
  }
}

/// Whether Pinax can see where a project's images are used, as Usage's one
/// switch. A flip is the commit, as
/// with the backend menu.
struct ProjectUsageTrackingSection: View {
  let row: ProjectSettingsRow
  @ObservedObject var model: ProjectSettingsModel

  static let title = "Track where images are used"
  static let note = "Untracked images never count as orphans."

  var selection: Binding<UsageTracking> {
    Binding(
      get: { row.usageTracking },
      set: { model.setUsageTracking($0, forProject: row.slug) }
    )
  }

  var body: some View {
    let selection = selection
    SettingsSection("Usage") {
      SettingsGroup {
        SettingsRow(Self.title, subtitle: Self.note) {
          SettingsRowSwitch(
            Self.title,
            isOn: Binding(
              get: { selection.wrappedValue == .tracked },
              set: { selection.wrappedValue = $0 ? .tracked : .notTracked }))
        }
      }
    }
  }
}

/// The page for one project: who it is, where its uploads
/// go, the folders Scan Now reads, and whether its usage is tracked.
///
/// Storage: its note says the menu and the fields change future uploads
/// only. The Key template sits under Key prefix, in the same group.
struct ProjectEditorView: View {
  let row: ProjectSettingsRow
  let backendSlugs: [String]
  @ObservedObject var model: ProjectSettingsModel
  @State private var prefixDraft: String
  @FocusState private var prefixFocused: Bool

  init(row: ProjectSettingsRow, backendSlugs: [String], model: ProjectSettingsModel) {
    self.row = row
    self.backendSlugs = backendSlugs
    self.model = model
    _prefixDraft = State(initialValue: row.keyPrefix)
  }

  /// A menu choice *is* the commit — the binding writes through the model,
  /// which re-reads the snapshot so the list updates immediately.
  var backendSelection: Binding<String?> {
    Binding(
      get: { row.backendSlug },
      set: { model.setBackend(slug: $0, forProject: row.slug) }
    )
  }

  /// Storage's note: one short sentence, as settings copy stays brief.
  static let storageNote = "Applies to new uploads only."
  static let ambiguousBackendWarning = "Several backends exist. Pick one."
  static let inheritTitle = "Inherit / none"

  /// The Backend row's subtitle: the ambiguity, only while it holds.
  var backendSubtitle: String? {
    row.backendSlug == nil && backendSlugs.count > 1 ? Self.ambiguousBackendWarning : nil
  }

  /// "Slug astro · 318 references" (the header's subtitle).
  static func headerSubtitle(_ row: ProjectSettingsRow) -> String {
    let count = row.referenceCount
    return "Slug \(row.slug) · \(count) \(count == 1 ? "reference" : "references")"
  }

  var body: some View {
    SettingsPage(leadingInset: DesignMetrics.settings.islandDetailGap) {
      // Rename… is not drawn: nothing renames a project.
      SettingsHeaderCard(row.name, subtitle: Self.headerSubtitle(row)) { EmptyView() }

      SettingsSection("Storage", note: Self.storageNote) {
        SettingsGroup {
          SettingsRow("Backend", subtitle: backendSubtitle) {
            SettingsMenuPicker("Backend", selection: backendSelection) {
              Text(Self.inheritTitle).tag(String?.none)
              ForEach(backendSlugs, id: \.self) { slug in
                Text(slug).tag(String?.some(slug))
              }
            } label: {
              Text(row.backendSlug ?? Self.inheritTitle)
            }
          }
          if let prefix = model.snapshot?.linksPrefix(for: row) {
            SettingsRowDivider()
            ProjectLinksUseRow(prefix: prefix)
          }
          SettingsRowDivider()
          SettingsRow("Key prefix") {
            // A key is code: the chip's mono size and ink, as Sources'
            // include rule. The system's focus ring is swapped for a
            // thinner one in the teal.
            TextField("Key prefix", text: $prefixDraft, prompt: Text("none"))
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .pinaxSettingsChip()
              .foregroundStyle(PinaxPalette.Settings.chipInk)
              .focused($prefixFocused)
              .focusEffectDisabled()
              .overlay {
                if prefixFocused {
                  RoundedRectangle(cornerRadius: DesignMetrics.settings.keyPrefixFieldRadius)
                    .strokeBorder(PinaxPalette.accentFill, lineWidth: DesignMetrics.settings.keyPrefixFocusRingWidth)
                }
              }
              .frame(width: DesignMetrics.settings.keyPrefixFieldWidth)
              .onSubmit(applyPrefix)
            Button("Set", action: applyPrefix)
              .disabled(prefixDraft == row.keyPrefix)
          }
          SettingsRowDivider()
          KeyTemplateBlock(row: row, keyPrefix: prefixDraft, model: model)
        }
      }

      ProjectSourcesSection(
        row: row, model: model, isScanning: model.scanActivity.map(Self.isRunning) ?? false)

      ProjectUsageTrackingSection(row: row, model: model)

      if let saveError = model.saveError {
        Text(saveError)
          .pinaxBody()
          .pinaxError()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private static func isRunning(_ activity: UsageScanActivity) -> Bool {
    if case .running = activity { return true }
    return false
  }

  private func applyPrefix() {
    model.setKeyPrefix(prefixDraft, forProject: row.slug)
  }
}

/// Storage's read-only Links use, the upload
/// backend's Current host; changed in Backends.
struct ProjectLinksUseRow: View {
  let prefix: String

  static let title = "Links use"

  static func help(_ prefix: String) -> String { "\(prefix) · Change it in Backends" }

  var body: some View {
    SettingsRow(Self.title) {
      Text(DomainHost.host(prefix))
        .pinaxSettingsValue()
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .help(Self.help(prefix))
  }
}
