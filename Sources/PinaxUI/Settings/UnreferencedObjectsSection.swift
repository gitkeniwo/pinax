import SwiftUI

/// Settings ▸ Backends ▸ <backend> ▸ Unreferenced Objects. It draws
/// `UnreferencedObjectsSectionContent` and nothing else.
struct BackendUnreferencedObjectsControls: View {
  let details: BackendDetails
  @ObservedObject var model: UnreferencedObjectsModel
  @Environment(\.openWindow) private var openWindow

  var content: UnreferencedObjectsSectionContent {
    .make(
      state: model.state, bucket: details.bucket,
      credentialsConfigured: details.credentialsConfigured, canImport: model.canImport)
  }

  /// The row's title, in the settings pages' sentence case (the content's
  /// `header` is the old Form section's).
  static let title = "Unreferenced objects"
  /// The row's subtitle, in place of the content's three-sentence footer.
  static let subtitle = "Objects in the bucket that aren't in the catalog."

  /// The status line under the row: from the first Find on, or when the
  /// content has something to say before it.
  var showsStatus: Bool {
    if case .notChecked = model.state { return !content.details.isEmpty }
    return true
  }

  var body: some View {
    let content = content
    // One Tools row as its neighbours, the explanation
    // a short subtitle; the status, progress and details in a row under it.
    Group {
      SettingsRow(Self.title, subtitle: Self.subtitle) {
        if let findTitle = content.findTitle {
          Button(findTitle) { Task { await model.find(backendSlug: details.slug) } }
            .disabled(!content.findEnabled)
        }
        if let importTitle = content.importTitle {
          Button(importTitle) { model.requestImport(bucket: details.bucket) }
        }
        if content.showsOrphansLink {
          Button("Show in Orphans") {
            openWindow(id: "gallery")
            model.showOrphans()
          }
        }
        if content.showsCancel {
          Button("Cancel") { model.cancelImport() }
        }
      }
      if showsStatus {
        VStack(alignment: .leading, spacing: DesignMetrics.settings.toolResultSpacing) {
          HStack(spacing: DesignMetrics.spacing.s) {
            if content.showsSpinner {
              ProgressView()
                .controlSize(.small)
            }
            Text(content.status)
              .pinaxBody()
              .monospacedDigit()
            if let progress = content.progress {
              ProgressView(value: progress)
                .frame(width: DesignMetrics.settings.progressBarWidth)
            }
          }
          ForEach(content.details, id: \.self) { line in
            if content.isError {
              Text(line)
                .pinaxBody()
                .pinaxError()
                .textSelection(.enabled)
            } else {
              Text(line)
                .pinaxSettingsRowSubtitle()
                .monospacedDigit()
            }
          }
        }
        .padding(.vertical, DesignMetrics.settings.rowVerticalPadding)
        .padding(.horizontal, DesignMetrics.settings.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.confirmation != nil },
        set: { shown in if !shown { model.dismissConfirmation() } })
    ) {
      if let confirmation = model.confirmation {
        ImportObjectsSheet(
          content: confirmation,
          onCancel: { model.dismissConfirmation() },
          onConfirm: { Task { await model.confirmImport(backendSlug: details.slug) } })
      }
    }
  }
}

/// "Import N Objects into the Catalog?" (H44Bucket ③).
struct ImportObjectsSheet: View {
  static let symbol = "arrow.down.to.line"

  let content: ImportObjectsSheetContent
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.l) {
      HStack(alignment: .top, spacing: DesignMetrics.spacing.m) {
        Image(systemName: Self.symbol)
          .imageScale(.large)
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
          Text(content.title)
            .pinaxTitle()
          Text(content.message)
            .pinaxSecondary()
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Grid(
        alignment: .leading, horizontalSpacing: DesignMetrics.spacing.l,
        verticalSpacing: DesignMetrics.spacing.xs
      ) {
        ForEach(content.rows, id: \.label) { row in
          GridRow {
            Text(row.label)
              .pinaxSecondary()
            Text(row.value)
              .pinaxBody()
              .monospacedDigit()
          }
        }
      }
      if let warning = content.cdnWarning {
        Text(warning)
          .pinaxSecondary()
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(content.note)
        .pinaxSecondary()
      HStack {
        Spacer()
        Button(content.cancelTitle, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(content.confirmTitle, action: onConfirm)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: DesignMetrics.settings.sheetWidth)
  }
}
