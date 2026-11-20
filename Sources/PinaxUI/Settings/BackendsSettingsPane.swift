import AppKit
import CatalogCore
import SwiftUI

struct BackendsSettingsPane: View {
  @ObservedObject var app: PinaxAppModel

  var body: some View {
    if let model = app.backends {
      BackendsSettingsContent(model: model)
    } else {
      Text("The catalog is not open yet.")
        .pinaxSecondary()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private typealias Metrics = DesignMetrics.settings

/// Settings ▸ Backends: the backends in the list
/// column — each with its kind, + at the foot — and the selected one's page
/// beside it: who it is with its credentials' state, Connection, Public URL,
/// Credentials, Tools. Nothing removes a backend, so there is no −.
struct BackendsSettingsContent: View {
  @ObservedObject var model: BackendsModel

  var body: some View {
    Group {
      if let rows = model.rows {
        HStack(spacing: DesignMetrics.spacing.none) {
          SettingsListColumn(
            icon: .backends,
            rows: rows.map { .init(id: $0.slug, name: $0.slug, subtitle: Self.kindName($0.kind)) },
            selection: selection,
            addLabel: "Add backend", removeLabel: "Remove backend",
            onAdd: { model.beginAddition() }, onRemove: nil)
          if rows.isEmpty {
            ContentUnavailableView(.noBackends) {
              Button("Add Backend…") { model.beginAddition() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            detail
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
    .task { await model.load() }
    .sheet(
      isPresented: Binding(
        get: { model.additionDraft != nil },
        set: { presented in if !presented { model.cancelAddition() } })
    ) {
      AddBackendSheet(model: model)
    }
  }

  /// A backend's kind in words (`S3-compatible`).
  static func kindName(_ kind: String) -> String {
    kind == "s3" ? "S3-compatible" : kind
  }

  /// The header's pill: the credentials' state.
  static func credentialsStatus(_ details: BackendDetails)
    -> (text: String, status: PinaxPalette.SettingsStatus)
  {
    details.credentialsConfigured ? ("Credentials OK", .pass) : ("No credentials", .warning)
  }

  private var selection: Binding<String?> {
    Binding(
      get: { model.selectedSlug },
      set: { slug in
        guard let slug else { return }
        Task { await model.select(slug) }
      })
  }

  @ViewBuilder
  private var detail: some View {
    if let details = model.details {
      let pill = Self.credentialsStatus(details)
      SettingsPage(leadingInset: Metrics.islandDetailGap) {
        SettingsHeaderCard(
          details.slug, subtitle: "\(Self.kindName(details.kind)) · bucket \(details.bucket)"
        ) {
          SettingsStatusPill(pill.text, status: pill.status)
        }
        BackendConnectionSection(details: details)
        BackendDomainsSection(details: details, model: model)
        BackendCredentialsControls(details: details, model: model)
        SettingsSection("Tools") {
          SettingsGroup {
            BackendPicGoImportControls(model: model)
            SettingsRowDivider()
            BackendReindexControls(details: details, model: model)
            SettingsRowDivider()
            BackendUnreferencedObjectsControls(details: details, model: model.unreferenced)
          }
        }
        if let operationMessage = model.operationMessage {
          Text(operationMessage)
            .pinaxSettingsRowSubtitle()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
}

extension View {
  /// A hand-built row's insets and height, as `SettingsRow` sets them.
  fileprivate func settingsRowInsets() -> some View {
    padding(.vertical, Metrics.rowVerticalPadding)
      .padding(.horizontal, Metrics.rowHorizontalPadding)
      .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
  }
}

/// Connection (`New-Backends`): Endpoint cut in the middle with a copy
/// button, Bucket, Region; each value selectable.
struct BackendConnectionSection: View {
  let details: BackendDetails

  var body: some View {
    SettingsSection("Connection") {
      SettingsGroup {
        SettingsRow("Endpoint") {
          // The host only, cut in the middle: a full account URL reads as
          // noise. The tooltip and the copy carry all of it.
          value(Self.shortEndpoint(details.endpoint))
            .truncationMode(.middle)
            .frame(maxWidth: Metrics.endpointValueMaxWidth, alignment: .trailing)
            .help(details.endpoint)
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details.endpoint, forType: .string)
          } label: {
            Image(systemName: "doc.on.doc")
              .resizable()
              .scaledToFit()
              .frame(width: Metrics.copyIconSize, height: Metrics.copyIconSize)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Copy endpoint")
          .help("Copy endpoint")
        }
        SettingsRowDivider()
        SettingsRow("Bucket") { value(details.bucket) }
        SettingsRowDivider()
        SettingsRow("Region") { value(details.region) }
      }
    }
  }

  /// "https://3bd8….r2.cloudflarestorage.com/" → its host; the text as
  /// given when it has none.
  static func shortEndpoint(_ endpoint: String) -> String {
    URL(string: endpoint)?.host() ?? endpoint
  }

  private func value(_ text: String) -> some View {
    Text(text)
      .pinaxSettingsValue()
      .lineLimit(1)
      .textSelection(.enabled)
  }
}

private struct BackendCredentialsControls: View {
  let details: BackendDetails
  @ObservedObject var model: BackendsModel

  var body: some View {
    SettingsSection("Credentials") {
      SettingsGroup {
        HStack(spacing: Metrics.rowSpacing) {
          VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
            Text("Access key")
            Text(BackendCredentialsControls.keychainLine(details))
              .pinaxSettingsRowSubtitle()
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
            SettingsCodeChip(BackendCredentialsControls.command(details.slug))
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Button(details.credentialsConfigured ? "Replace…" : "Set…") {
            model.beginCredentialsEntry()
          }
          .disabled(details.keychainReference.isEmpty || model.isSavingCredentials)
        }
        .settingsRowInsets()

        if model.isCredentialsFormPresented {
          SettingsRowDivider()
          SettingsRow("Access key ID") {
            SecureField("Access key ID", text: accessKeyID)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          SettingsRowDivider()
          SettingsRow("Secret access key") {
            SecureField("Secret access key", text: secretAccessKey)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          SettingsRowDivider()
          HStack {
            Spacer()
            Button("Cancel") { model.cancelCredentialsEntry() }
            Button("Save Credentials") {
              Task { await model.submitCredentials() }
            }
            .disabled(!model.canSubmitCredentials)
          }
          .settingsRowInsets()
        }

        if model.isSavingCredentials || model.credentialsSaveError != nil {
          SettingsRowDivider()
          HStack {
            if model.isSavingCredentials {
              ProgressView()
                .controlSize(.small)
            }
            if let error = model.credentialsSaveError {
              Text(error)
                .pinaxBody()
                .pinaxError()
            }
          }
          .settingsRowInsets()
        }
      }
    }
  }

  /// "Keychain: backend.r2"; the Terminal command is the chip under it.
  static func keychainLine(_ details: BackendDetails) -> String {
    details.keychainReference.isEmpty
      ? "No Keychain entry"
      : "Keychain: \(details.keychainReference)"
  }

  static func command(_ slug: String) -> String {
    "pinax backend set-credentials --slug \(slug)"
  }

  private var accessKeyID: Binding<String> {
    Binding(
      get: { model.credentialAccessKeyID },
      set: { model.updateCredentialAccessKeyID($0) })
  }

  private var secretAccessKey: Binding<String> {
    Binding(
      get: { model.credentialSecretAccessKey },
      set: { model.updateCredentialSecretAccessKey($0) })
  }
}

/// Tools ▸ Import PicGo gallery: Choose File… and a dry run on the row;
/// the dry run's result brings Import under it.
struct BackendPicGoImportControls: View {
  @ObservedObject var model: BackendsModel

  static let title = "Import PicGo gallery"

  var body: some View {
    let file = (model.picGoSourceURL.path as NSString).abbreviatingWithTildeInPath
    SettingsRow(Self.title, subtitle: file) {
      Button("Choose File…") { model.choosePicGoGallery() }
        .disabled(model.isImportingPicGo)
      Button("Dry Run…") { Task { await model.runPicGoDryRun() } }
        .disabled(!model.canRunPicGoImport)
    }
    .help(model.picGoSourceURL.path)

    if model.isImportingPicGo || model.picGoDryRunResult != nil
      || model.picGoAppliedResult != nil || model.picGoImportError != nil
    {
      VStack(alignment: .leading, spacing: Metrics.toolResultSpacing) {
        if model.isImportingPicGo {
          Text("Importing…")
            .pinaxSettingsRowSubtitle()
        }
        if let result = model.picGoDryRunResult {
          PicGoImportResultView(title: "Dry-run result", result: result)
          HStack {
            Spacer()
            Button("Import", role: .destructive) {
              Task { await model.applyPicGoImport() }
            }
            .disabled(!model.canApplyPicGoImport)
          }
        }
        if let result = model.picGoAppliedResult {
          PicGoImportResultView(title: "Import result", result: result)
        }
        if let error = model.picGoImportError {
          Text(error)
            .pinaxBody()
            .pinaxError()
            .textSelection(.enabled)
        }
      }
      .settingsRowInsets()
    }
  }
}

private struct PicGoImportResultView: View {
  let title: String
  let result: PicGoImportResult

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      Text(title)
        .pinaxSectionTitle()
      Text("Schema: \(result.schema)")
      Text("Dry run: \(result.dryRun ? "Yes" : "No")")
      Text("Records read: \(result.recordsRead)")
      Text("Distinct keys: \(result.distinctKeys)")
      Text("Imported: \(result.imported)")
      Text("Already present: \(result.alreadyPresent)")
      Text("Duplicate source records: \(result.duplicateSourceRecords)")
      Text("Imported via retired prefix: \(result.importedViaRetiredPrefix)")
      Text("Skipped: \(result.skipped.count)")
      ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, item in
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs / 2) {
          Text("\(item.reason): \(item.url)")
          if let detail = item.detail {
            Text(detail)
          }
        }
        .pinaxCaption()
      }
    }
    .pinaxBody()
    .monospacedDigit()
    .textSelection(.enabled)
  }
}

/// Tools ▸ Reindex bucket: a dry run on the row; its result brings Apply
/// Reindex under it.
struct BackendReindexControls: View {
  static let title = "Reindex bucket"
  static let description = "Rebuilds the catalog from the bucket."
  static let missingCredentialsText = "Set credentials first."

  let details: BackendDetails
  @ObservedObject var model: BackendsModel

  var body: some View {
    SettingsRow(
      Self.title,
      subtitle: details.credentialsConfigured ? Self.description : Self.missingCredentialsText
    ) {
      Button("Dry Run…") { Task { await model.runReindexDryRun() } }
        .disabled(!model.canRunReindex)
    }

    if model.isReindexing || model.reindexDryRunResult != nil
      || model.reindexAppliedResult != nil || model.reindexError != nil
    {
      VStack(alignment: .leading, spacing: Metrics.toolResultSpacing) {
        if model.isReindexing {
          Text("Reindexing…")
            .pinaxSettingsRowSubtitle()
        }
        if let result = model.reindexDryRunResult {
          ReindexResultView(title: "Dry-run result", result: result)
          HStack {
            Spacer()
            Button("Apply Reindex", role: .destructive) {
              Task { await model.applyReindex() }
            }
            .disabled(!model.canApplyReindex)
          }
        }
        if let result = model.reindexAppliedResult {
          ReindexResultView(title: "Applied result", result: result)
        }
        if let reindexError = model.reindexError {
          Text(reindexError)
            .pinaxBody()
            .pinaxError()
            .textSelection(.enabled)
        }
      }
      .settingsRowInsets()
    }
  }
}

private struct ReindexResultView: View {
  let title: String
  let result: ReindexResult

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      Text(title)
        .pinaxSectionTitle()
      Text("Schema: \(result.schema)")
      Text("Dry run: \(result.dryRun ? "Yes" : "No")")
      Text("Scanned: \(result.scanned)")
      Text("Reconstructed: \(result.reconstructed)")
      Text("Existing: \(result.existing)")
      Text("Missing metadata: \(result.missingMetadata.count)")
      ForEach(Array(result.missingMetadata.enumerated()), id: \.offset) { _, item in
        Text("\(item.key): \(item.missing.joined(separator: ", "))")
          .pinaxCaption()
      }
    }
    .pinaxBody()
    .monospacedDigit()
    .textSelection(.enabled)
  }
}

/// The Domains card in place of
/// Public URL — the Current first, each Old domain under it with its links
/// or Unused, ⋯ menus, Add Old Domain at the foot (inline), and Switch
/// Without Rewriting… in a small sheet. The two Move buttons only hand
/// over to the main window.
struct BackendDomainsSection: View {
  let details: BackendDetails
  @ObservedObject var model: BackendsModel
  @Environment(\.openWindow) private var openWindow
  @State private var removing: BackendDomainRow?

  static let title = "Domains"
  static let addNote = "Only to recognize links. Files stay as they are."
  /// The sheet keeps one sentence; the rest is the
  /// ⓘ popover and the menu item's tooltip.
  static let switchNote = "The current domain joins Old domains."
  static let switchHelp =
    "Pinax only changes which domain it uses for new links. Your files keep their links; to rewrite them, use Move to New Domain…"

  var body: some View {
    SettingsSection(Self.title) {
      SettingsGroup {
        ForEach(model.domainRows) { row in
          if !row.isCurrent { SettingsRowDivider() }
          domainRow(row)
        }
        SettingsRowDivider()
        footer
      }
    }
    .confirmationDialog(
      "Remove \(removing?.host ?? "")?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        if let prefix = removing?.prefix { Task { await model.removeOldDomain(prefix) } }
        removing = nil
      }
      Button("Cancel", role: .cancel) { removing = nil }
    } message: {
      Text("Links on it will no longer count as your images.")
    }
    .sheet(
      isPresented: Binding(
        get: { model.switchDraft != nil },
        set: { if !$0 { model.cancelSwitch() } })
    ) {
      BackendSwitchSheet(details: details, model: model)
    }
  }

  private func domainRow(_ row: BackendDomainRow) -> some View {
    HStack(spacing: Metrics.rowSpacing) {
      HStack(spacing: DesignMetrics.spacing.s) {
        Text(row.host)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(row.prefix)
        if row.isCurrent {
          Text("Current")
            .font(.caption.weight(.semibold))
            .foregroundStyle(PinaxPalette.accent)
            .fixedSize()
        }
        if let links = row.linksText {
          Text(links)
            .pinaxSettingsRowSubtitle()
            .monospacedDigit()
            .fixedSize()
            .help(row.isUnused ? DomainCopy.unusedHelp : "")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if row.isCurrent {
        Button("Move to New Domain…") { move { model.moveToNewDomain() } }
          .disabled(!model.canMove)
          .help(model.moveHelp ?? "")
      } else if let title = row.moveTitle {
        Button(title) { move { model.moveToCurrent(row.prefix) } }
          .disabled(!model.canMove)
          .help(model.moveHelp ?? "")
      }
      menu(row)
    }
    .settingsRowInsets()
  }

  /// A Move opens the main window, where the sheet is.
  private func move(_ action: () -> Void) {
    openWindow(id: "gallery")
    action()
  }

  private func menu(_ row: BackendDomainRow) -> some View {
    Menu {
      if row.isCurrent {
        Button("Switch Without Rewriting…") { model.beginSwitch() }
          .disabled(model.isMigrationBusy)
          .help(BackendDomainsSection.switchHelp)
        Button("Copy URL") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(row.prefix, forType: .string)
        }
      } else if row.isUnused {
        Button("Remove") { Task { await model.removeOldDomain(row.prefix) } }
          .disabled(model.isMigrationBusy || !model.canEditOldDomains)
      } else {
        Button("Remove…") { removing = row }
          .disabled(model.isMigrationBusy || !model.canEditOldDomains)
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("More for \(row.host)")
    .help("More")
  }

  @ViewBuilder
  private var footer: some View {
    if let draft = model.oldDomainDraft {
      HStack(alignment: .firstTextBaseline, spacing: Metrics.rowSpacing) {
        VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
          TextField(
            "Old domain",
            text: Binding(get: { draft }, set: { model.updateOldDomainDraft($0) }),
            prompt: Text("https://old.example.com"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await model.submitOldDomain() } }
          if let error = model.oldDomainError {
            Text(error)
              .pinaxSettingsRowSubtitle()
              .pinaxError()
          } else {
            Text(Self.addNote)
              .pinaxSettingsRowSubtitle()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button("Cancel") { model.cancelOldDomainAddition() }
        Button("Add") { Task { await model.submitOldDomain() } }
          .disabled(!model.canSubmitOldDomain)
      }
      .settingsRowInsets()
    } else {
      HStack {
        Button("Add Old Domain") { model.beginOldDomainAddition() }
          .disabled(!model.canEditOldDomains || model.isMigrationBusy)
          .help(model.isMigrationBusy ? MigrationLock.busyHelp : "")
        Spacer()
      }
      .settingsRowInsets()
    }
  }
}

/// Switch Without Rewriting: From, To, one sentence, Cancel and Switch. A Old
/// domain can be typed to switch back.
struct BackendSwitchSheet: View {
  let details: BackendDetails
  @ObservedObject var model: BackendsModel
  @State private var showsInfo = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      HStack(spacing: DesignMetrics.spacing.xs) {
        Text("Switch Without Rewriting")
          .pinaxTitle()
        // What Switch leaves alone, on demand.
        Button { showsInfo.toggle() } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("About Switch Without Rewriting")
        .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
          Text(BackendDomainsSection.switchHelp)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
            .padding(DesignMetrics.spacing.m)
        }
      }
      Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: DesignMetrics.spacing.s) {
        GridRow {
          Text("From:").gridColumnAlignment(.trailing)
          Text(DomainHost.host(details.urlPrefix))
            .help(details.urlPrefix)
        }
        GridRow {
          Text("To:")
          VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
            TextField(
              "To", text: Binding(get: { model.switchDraft ?? "" }, set: { model.updateSwitchDraft($0) }),
              prompt: Text(DomainCopy.toPlaceholder))
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .onSubmit { Task { await model.submitSwitch() } }
            if let error = model.switchError {
              Text(error)
                .pinaxSettingsRowSubtitle()
                .pinaxError()
            }
          }
        }
      }
      Text(BackendDomainsSection.switchNote)
        .pinaxSettingsRowSubtitle()
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel") { model.cancelSwitch() }
          .keyboardShortcut(.cancelAction)
        Button("Switch") { Task { await model.submitSwitch() } }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSubmitSwitch)
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: 440)
  }
}

private struct AddBackendSheet: View {
  @ObservedObject var model: BackendsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Backend")
        .pinaxTitle()
      Form {
        TextField("Slug", text: draftBinding(\.slug))
        TextField("Endpoint", text: draftBinding(\.endpoint))
        TextField("Bucket", text: draftBinding(\.bucket))
        TextField("Region", text: draftBinding(\.region))
        TextField("URL prefix", text: draftBinding(\.urlPrefix))
        TextField("Keychain reference", text: draftBinding(\.keychainReference))
      }
      Text("Credentials are not entered here. Configure them later with the CLI.")
        .pinaxSecondary()
      if let loadError = model.loadError {
        Text(loadError)
          .pinaxBody()
          .pinaxError()
      }
      HStack {
        Spacer()
        Button("Cancel") { model.cancelAddition() }
          .keyboardShortcut(.cancelAction)
        Button("Create") { Task { await model.submitAddition() } }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSubmitAddition || model.isAddingBackend)
      }
    }
    .padding(20)
    .frame(width: 420)
    .disabled(model.isAddingBackend)
  }

  private func draftBinding(
    _ keyPath: WritableKeyPath<NewBackendDraft, String>
  ) -> Binding<String> {
    Binding(
      get: { model.additionDraft?[keyPath: keyPath] ?? "" },
      set: { value in model.updateAdditionDraft { $0[keyPath: keyPath] = value } })
  }
}
