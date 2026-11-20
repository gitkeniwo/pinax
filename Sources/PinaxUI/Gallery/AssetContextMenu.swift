import SwiftUI

/// The asset context menu for the cell or row
/// the menu was opened on: a thin renderer for
/// `GalleryModel.contextMenuItems(for:)`, whose targets follow the one rule —
/// outside the selection, that row alone; inside a selection of two or more,
/// the selection. Both gallery grids, the orphan grid (`assetContextMenu`)
/// and the table's rows (`AssetTableRow`) render this one menu, so
/// their capabilities cannot drift apart. Add Tag… and Edit Note… open the
/// gallery's one context editor, anchored on this row.
struct AssetContextMenuItems: View {
  @ObservedObject var model: GalleryModel
  let row: GalleryModel.Row

  var body: some View {
    ForEach(model.contextMenuItems(for: row)) { item in
      menuItem(item)
    }
    if !model.usageMenuItems(for: row).isEmpty {
      Divider()
      UsageMenuItems(model: model, row: row)
    }
  }

  @ViewBuilder
  private func menuItem(_ item: GalleryModel.ContextMenuItem) -> some View {
    switch item {
    case let .copyURL(target):
      Button("Copy URL") {
        model.copyURL(for: target)
      }
    case let .copyAs(target, formats):
      Menu("Copy As") {
        ForEach(formats) { format in
          Button(format.name) {
            model.copy(format, for: target)
          }
        }
      }
      .disabled(formats.isEmpty)
    case let .downloadOriginal(target):
      Button("Download Original") {
        Task { await model.downloadOriginals(for: target) }
      }
      .disabled(model.isDownloading)
    case let .addTag(target):
      Button("Add Tag…") {
        model.beginContextTagEditing(for: target, anchor: row.id)
      }
    case let .addToProject(target, projects):
      Menu("Add to Project") {
        ForEach(projects) { project in
          Button(project.name) {
            Task {
              await model.setProjectMembership(true, slug: project.slug, for: target)
            }
          }
          .disabled(project.isMember)
        }
      }
    case let .editNote(target):
      Button("Edit Note…") {
        model.beginContextNoteEditing(for: target, anchor: row.id)
      }
    case let .favorite(target, isFavorite):
      Divider()
      Button(isFavorite ? "Unfavorite" : "Favorite") {
        Task { await model.toggleFavorite(target) }
      }
    case let .label(target, choices):
      Menu("Label") {
        ForEach(choices) { choice in
          Toggle(isOn: Binding(
            get: { choice.state == true },
            set: { _ in Task { await model.toggleLabel(choice.label, for: target) } }
          )) {
            Label {
              Text(choice.label.title)
            } icon: {
              Image(systemName: "circle.fill")
                .foregroundStyle(choice.label.color)
            }
          }
        }
      }
    case let .archive(target, putBack):
      Divider()
      Button(putBack ? "Put Back" : "Archive") {
        Task {
          if putBack {
            await model.putBack(target)
          } else {
            await model.archive(target)
          }
        }
      }
    case let .deletePermanently(target, isEnabled):
      // Plain text colour, as Finder's Delete Immediately….
      Button("Delete Permanently…") {
        Task { await model.deletePermanently(target) }
      }
      .disabled(!isEnabled)
    }
  }
}

/// The popover Add Tag… and Edit Note… open beside the right-clicked cell
/// or row, shown while the gallery's `contextEditor` names it.
/// Clicking outside closes it — saving a note; Esc in a note discards,
/// whether the Cancel button or the popover itself takes it.
struct AssetContextEditorPopover: ViewModifier {
  @ObservedObject var model: GalleryModel
  let rowID: GalleryModel.Row.ID

  func body(content: Content) -> some View {
    content
      .popover(
        isPresented: Binding(
          get: { model.contextEditor?.anchor == rowID },
          set: { if !$0 { model.contextEditorDidClose() } }),
        arrowEdge: .trailing
      ) {
        AssetContextEditorContent(model: model)
      }
  }
}

/// The popover's content: Add Tag in the shape of Xcode's branch popover —
/// a field over the catalog's tags, filtered as you type — or the note.
struct AssetContextEditorContent: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    switch model.contextEditor?.kind {
    case .tag?:
      ContextTagEditor(model: model)
    case .note?:
      ContextNoteEditor(model: model)
    case nil:
      EmptyView()
    }
  }
}

struct ContextTagEditor: View {
  @ObservedObject var model: GalleryModel
  @FocusState private var fieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.s) {
      TextField("Tag", text: $model.contextTagQuery)
        .textFieldStyle(.roundedBorder)
        .focused($fieldFocused)
        .onSubmit { Task { await model.submitContextTag() } }
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
          model.moveContextTagHighlight(by: press.key == .upArrow ? -1 : 1)
          return .handled
        }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.contextTagSuggestions) { suggestion in
            suggestionRow(suggestion)
          }
        }
      }
      .frame(maxHeight: DesignMetrics.contextEditor.listMaxHeight)
    }
    .padding(DesignMetrics.spacing.m)
    .frame(width: DesignMetrics.contextEditor.width)
    .onAppear { fieldFocused = true }
  }

  private func suggestionRow(_ suggestion: GalleryModel.ContextTagSuggestion) -> some View {
    HStack(spacing: DesignMetrics.spacing.xs) {
      Image(systemName: "checkmark")
        .foregroundStyle(PinaxPalette.accent)
        .opacity(suggestion.isOnTarget ? 1 : 0)
      Text(suggestion.name)
        .pinaxBody()
        .lineLimit(1)
    }
    .padding(.horizontal, DesignMetrics.spacing.xs)
    .padding(.vertical, DesignMetrics.spacing.xs / 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      if suggestion.name == model.contextTagHighlight {
        RoundedRectangle(cornerRadius: DesignMetrics.radius.chip).fill(.quaternary)
      }
    }
    .contentShape(Rectangle())
  }
}

struct ContextNoteEditor: View {
  @ObservedObject var model: GalleryModel
  @FocusState private var editorFocused: Bool

  var body: some View {
    VStack(alignment: .trailing, spacing: DesignMetrics.spacing.s) {
      TextEditor(text: $model.noteDraft)
        .pinaxBody()
        .focused($editorFocused)
        .frame(minHeight: DesignMetrics.contextEditor.noteMinHeight)
      HStack {
        // Esc and ⌘Return, as key equivalents the popover's window handles
        // before the text view would take them.
        Button("Cancel") { model.dismissContextEditor(saving: false) }
          .keyboardShortcut(.cancelAction)
        Button("Save") { model.dismissContextEditor(saving: true) }
          .keyboardShortcut(.return, modifiers: .command)
      }
      .controlSize(.small)
    }
    .padding(DesignMetrics.spacing.m)
    .frame(width: DesignMetrics.contextEditor.width)
    .onAppear { editorFocused = true }
  }
}

/// The grid cells' context menu: the shared menu and its popover, per cell.
struct AssetContextMenuModifier: ViewModifier {
  @ObservedObject var model: GalleryModel
  let row: GalleryModel.Row

  func body(content: Content) -> some View {
    content
      .contextMenu {
        AssetContextMenuItems(model: model, row: row)
      }
      .modifier(AssetContextEditorPopover(model: model, rowID: row.id))
  }
}

extension View {
  func assetContextMenu(model: GalleryModel, row: GalleryModel.Row) -> some View {
    modifier(AssetContextMenuModifier(model: model, row: row))
  }

  /// The context editor's popover on a table row's Name cell.
  func assetContextEditorPopover(model: GalleryModel, row: GalleryModel.Row) -> some View {
    modifier(AssetContextEditorPopover(model: model, rowID: row.id))
  }
}

/// What Usage adds to a row's menu; a table child row —
/// one reference — has only these.
struct UsageMenuItems: View {
  @ObservedObject var model: GalleryModel
  let row: GalleryModel.Row

  var body: some View {
    ForEach(model.usageMenuItems(for: row)) { item in
      switch item {
      case let .openFile(url):
        Button("Open File") { NSWorkspace.shared.open(url) }
      case let .revealInFinder(url):
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      case let .copyNewURL(url):
        Button("Copy New URL") { PasteboardWriter.copy(url) }
      case let .showInLibrary(assetID):
        Button("Show in Library") {
          Task { await model.showInLibrary(assetID: assetID) }
        }
      }
    }
  }
}
