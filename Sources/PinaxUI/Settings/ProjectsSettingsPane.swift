import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

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

/// How a project's uploads are compressed: a switch, then the longest
/// edge, the quality and whether metadata goes. Only the uploaded copy is
/// compressed. Every choice is written at once; while the switch is off the
/// three rows below it keep their values but are disabled and dimmed, as
/// the Drop Zone page's sections are under its switch.
struct ProjectCompressionSection: View {
  let row: ProjectSettingsRow
  @ObservedObject var model: ProjectSettingsModel

  static let title = "Compression"
  static let enabledTitle = "Compress on upload"
  static let longestEdgeTitle = "Longest edge"
  static let qualityTitle = "Quality"
  static let metadataTitle = "Remove metadata"
  static let metadataNote = "Includes location."
  static let dontResize = "Don't resize"
  /// The menu's sizes, in pixels; Don't resize follows a divider.
  static let longestEdges = [1600, 2048, 2560, 3840]

  /// "2048 px", or Don't resize.
  static func longestEdgeLabel(_ edge: Int?) -> String {
    edge.map { "\($0) px" } ?? dontResize
  }

  /// "85%".
  static func qualityLabel(_ quality: CompressionQuality) -> String {
    quality.description
  }

  /// The menu's sizes, plus a stored one that is not among them (set from
  /// the command line) so the menu can still mark it.
  var edgeChoices: [Int] {
    guard let edge = row.compression.options.longestEdge, !Self.longestEdges.contains(edge) else {
      return Self.longestEdges
    }
    return (Self.longestEdges + [edge]).sorted()
  }

  var isEnabled: Binding<Bool> {
    binding(\.isEnabled)
  }

  var longestEdge: Binding<Int?> {
    binding(\.options.longestEdge)
  }

  var quality: Binding<CompressionQuality> {
    binding(\.options.quality)
  }

  var removesMetadata: Binding<Bool> {
    binding(\.options.removesMetadata)
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<ProjectCompression, Value>) -> Binding<Value> {
    Binding(
      get: { row.compression[keyPath: keyPath] },
      set: { value in model.setCompression(forProject: row.slug) { $0[keyPath: keyPath] = value } })
  }

  var body: some View {
    let compression = row.compression
    SettingsSection(Self.title) {
      SettingsGroup {
        SettingsRow(Self.enabledTitle) {
          SettingsRowSwitch(Self.enabledTitle, isOn: isEnabled)
        }
        SettingsRowDivider()
        Group {
          SettingsRow(Self.longestEdgeTitle) {
            SettingsMenuPicker(Self.longestEdgeTitle, selection: longestEdge) {
              ForEach(edgeChoices, id: \.self) { edge in
                Text(Self.longestEdgeLabel(edge)).tag(Int?.some(edge))
              }
              Divider()
              Text(Self.dontResize).tag(Int?.none)
            } label: {
              Text(Self.longestEdgeLabel(compression.options.longestEdge))
            }
          }
          SettingsRowDivider()
          SettingsRow(Self.qualityTitle) {
            SettingsQualitySlider(Self.qualityTitle, quality: quality)
          }
          SettingsRowDivider()
          SettingsRow(Self.metadataTitle, subtitle: Self.metadataNote) {
            SettingsRowSwitch(Self.metadataTitle, isOn: removesMetadata)
          }
        }
        .disabled(!compression.isEnabled)
        .opacity(compression.isEnabled ? 1 : Metrics.disabledOpacity)
      }
    }
  }
}

/// The Quality row's control: a slider over 40–100 in steps of 1, with tick
/// marks where the three named steps of earlier versions sat, and the value
/// as "85%" after it. A drag moves only the knob and the number; the value
/// is written once, when the knob is let go. A keyboard or accessibility
/// step writes at once.
struct SettingsQualitySlider: View {
  let title: String
  @Binding var quality: CompressionQuality
  /// The knob's value mid-drag; nil otherwise, so the knob shows the stored
  /// value.
  @State private var dragValue: Double?
  @State private var isDragging = false

  init(_ title: String, quality: Binding<CompressionQuality>) {
    self.title = title
    self._quality = quality
  }

  static let bounds = Double(CompressionQuality.range.lowerBound)...Double(CompressionQuality.range.upperBound)

  /// Where a tick for `percent` sits along a track `width` wide, measured
  /// from the slider's leading edge.
  static func tickOffset(_ percent: Int, width: CGFloat) -> CGFloat {
    let travel = width - 2 * Metrics.qualityTickInset
    let fraction = (Double(percent) - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
    return Metrics.qualityTickInset + travel * fraction
  }

  /// The quality a slider value stands for: rounded to a whole percent.
  static func quality(forSliderValue value: Double) -> CompressionQuality {
    CompressionQuality(Int(value.rounded()))
  }

  private var shown: CompressionQuality {
    dragValue.map(Self.quality(forSliderValue:)) ?? quality
  }

  private var sliderValue: Binding<Double> {
    Binding(
      get: { dragValue ?? Double(quality.percent) },
      set: { value in
        if isDragging {
          dragValue = value
        } else {
          commit(value)
        }
      })
  }

  private func commit(_ value: Double) {
    let next = Self.quality(forSliderValue: value)
    if next != quality { quality = next }
  }

  var body: some View {
    HStack(spacing: Metrics.qualityValueSpacing) {
      Slider(value: sliderValue, in: Self.bounds, step: 1) { editing in
        isDragging = editing
        if !editing, let dragValue {
          self.dragValue = nil
          commit(dragValue)
        }
      }
      .labelsHidden()
      .tint(PinaxPalette.accentFill)
      .controlSize(.small)
      .frame(width: Metrics.qualitySliderWidth)
      .overlay(alignment: .bottomLeading) {
        ZStack(alignment: .leading) {
          ForEach(CompressionQuality.ticks, id: \.self) { percent in
            Rectangle()
              .fill(.tertiary)
              .frame(width: Metrics.qualityTickWidth, height: Metrics.qualityTickHeight)
              .offset(
                x: Self.tickOffset(percent, width: Metrics.qualitySliderWidth)
                  - Metrics.qualityTickWidth / 2)
          }
        }
        .offset(y: Metrics.qualityTickHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      .accessibilityLabel(title)
      .accessibilityValue(shown.description)
      Text(shown.description)
        .monospacedDigit()
        .frame(width: Metrics.qualityValueWidth, alignment: .trailing)
    }
  }
}

/// The page for one project: who it is, where its uploads
/// go and how they are compressed, the folders Scan Now reads, and whether
/// its usage is tracked.
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

      ProjectCompressionSection(row: row, model: model)

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
