import SwiftUI

/// Delete Permanently…'s sheet: one
/// layout, rows and notes added by case; every string comes from
/// `DeletionConfirmation`. Cancel is the default (Return cancels) —
/// except when Remove from <project> is offered, which is the default then.
struct DeletionConfirmationSheet: View {
  let confirmation: DeletionConfirmation
  let cancel: () -> Void
  let delete: () -> Void
  let removeFromProject: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text(confirmation.title)
        .pinaxTitle()
      Text(confirmation.subtitle)
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
      Form {
        Section {
          ForEach(confirmation.lines, id: \.label) { line in
            LabeledContent(line.label) {
              Text(line.value)
                .monospacedDigit()
            }
          }
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
      ForEach(confirmation.notes, id: \.title) { note in
        DeletionNoteView(note: note)
      }
      Text(confirmation.finePrint)
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if confirmation.removal != nil {
          // Board 2b: the destructive button moves left, secondary.
          Button(confirmation.deleteTitle, role: .destructive, action: delete)
          Spacer()
          Button("Cancel", action: cancel)
            .keyboardShortcut(.cancelAction)
          Button(confirmation.removeTitle ?? "", action: removeFromProject)
            .keyboardShortcut(.defaultAction)
        } else {
          Spacer()
          Button(confirmation.deleteTitle, role: .destructive, action: delete)
          Button("Cancel", action: cancel)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: DesignMetrics.backupSheet.width)
    // Esc cancels too, whichever button holds Return.
    .onExitCommand(perform: cancel)
  }
}

/// One of the sheet's warnings (still used, imported, Remove from): a
/// warning symbol, a title, the sentence, and — for files — the list.
private struct DeletionNoteView: View {
  let note: DeletionConfirmation.Note

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
      Image(systemName: "exclamationmark.triangle.fill")
        .symbolRenderingMode(.multicolor)
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
        Text(note.title)
          .pinaxSectionTitle()
        Text(note.detail)
          .pinaxSecondary()
          .fixedSize(horizontal: false, vertical: true)
        ForEach(note.items, id: \.self) { item in
          Text(item)
            .pinaxMono()
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
  }
}

/// Archived's banner: deletions that did not finish,
/// why, and Show Files / Restore to Library / Retry. Closable; the sidebar
/// badge stays. While restoring it reads "Checking <bucket>…" with both
/// buttons disabled.
struct DeletionBannerView: View {
  @ObservedObject var model: GalleryModel
  let banner: DeletionBanner

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.s) {
      HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.m) {
        if model.isRestoringDeletions {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
        }
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
          Text(banner.title)
            .pinaxSectionTitle()
          Text(banner.detail)
            .pinaxSecondary()
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: DesignMetrics.spacing.m)
        if !model.isRestoringDeletions {
          Button(model.showsUnfinishedFiles ? "Hide Files" : "Show Files") {
            model.showsUnfinishedFiles.toggle()
          }
          .buttonStyle(.link)
        }
        Button("Restore to Library") {
          Task { await model.restoreUnfinishedDeletions() }
        }
        Button("Retry") {
          Task { await model.retryUnfinishedDeletions() }
        }
        Button {
          model.dismissDeletionBanner()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Close")
      }
      .disabled(model.isDeletionBusy)
      if model.showsUnfinishedFiles {
        ForEach(model.unfinishedDeletions) { item in
          Text(item.key)
            .pinaxMono()
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, ChromeMetrics.horizontalPadding)
    .padding(.vertical, DesignMetrics.spacing.s)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
}
