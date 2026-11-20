import SwiftUI

/// The window's title area, in Xcode's shape: the
/// sidebar's leaf row over the current project, which is a button that
/// opens the project picker. The system title is hidden by the window's
/// toolbar style; `navigationTitle` / `navigationSubtitle` still set
/// `window.title` and `window.subtitle` for the Window menu and
/// accessibility.
///
/// Measured on macOS 15.7.8: a `.navigation` item
/// with the system title hidden sits where the title was — left edge of
/// the content section, title on top — and takes clicks; hiding the title
/// through `titleVisibility` alone shrank the toolbar by 14 pt, the unified
/// toolbar style keeps it at the system title's height. Final build, 900 ×
/// 695 window: toolbar 52 pt, the item at x 233.5, y 654–684 (the system
/// title and subtitle spanned x 231, y 654–684), its button hit-tests.
struct ProjectTitleItem: View {
  @ObservedObject var model: GalleryModel
  let title: WindowTitle

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.projectPicker.stackSpacing) {
      Text(title.title)
        .pinaxBody()
        .bold()
        .lineLimit(1)
      Button {
        model.isProjectPickerPresented.toggle()
      } label: {
        // The project's symbol,
        // its name and a chevron, all secondary, on no ground.
        HStack(spacing: DesignMetrics.projectPicker.chevronSpacing) {
          Image(systemName: Self.projectSymbol(model.currentProjectSlug))
            .imageScale(.small)
          Text(title.subtitle)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .imageScale(.small)
        }
        .pinaxSecondary()
      }
      .buttonStyle(.plain)
      .modifier(ProjectPickerPopover(model: model))
    }
  }

  /// The project line's symbol, the picker rows' too: all projects, or one.
  static func projectSymbol(_ slug: String?) -> String {
    slug == nil ? "rectangle.stack.fill" : "folder.fill"
  }
}

/// The picker's popover on the project line, shown while the gallery's
/// `isProjectPickerPresented` says so — the state ⌃0 sets too.
struct ProjectPickerPopover: ViewModifier {
  @ObservedObject var model: GalleryModel

  func body(content: Content) -> some View {
    content
      .popover(
        isPresented: Binding(
          get: { model.isProjectPickerPresented },
          set: { model.isProjectPickerPresented = $0 }),
        arrowEdge: .bottom
      ) {
        ProjectPickerView(model: model)
      }
  }
}

/// The popover's content, after Xcode's branch popover: Find over the
/// projects, the current one in its own section, every row two lines;
/// ↑ ↓ move, Return chooses, Esc closes, a click chooses.
struct ProjectPickerView: View {
  @ObservedObject var model: GalleryModel
  @FocusState private var fieldFocused: Bool

  var body: some View {
    let sections = model.projectPickerSections
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.s) {
      TextField("Find", text: $model.projectPickerQuery)
        .textFieldStyle(.roundedBorder)
        .focused($fieldFocused)
        .onSubmit { model.chooseHighlightedProject() }
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
          model.moveProjectPickerHighlight(by: press.key == .upArrow ? -1 : 1)
          return .handled
        }
        // Esc reaches the field editor before `onKeyPress` (see
        // `EscapeMonitor`).
        .background(EscapeMonitor(focus: $fieldFocused) { model.isProjectPickerPresented = false })
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DesignMetrics.projectPicker.stackSpacing) {
          if !sections.current.isEmpty {
            sectionTitle("Current Project")
            ForEach(rowViews(sections.current), id: \.row.id) { $0 }
          }
          if !sections.others.isEmpty {
            sectionTitle("Projects")
            ForEach(rowViews(sections.others), id: \.row.id) { $0 }
          }
        }
      }
      .frame(maxHeight: DesignMetrics.projectPicker.listMaxHeight)
      .fixedSize(horizontal: false, vertical: true)
      Divider()
      VStack(alignment: .leading, spacing: DesignMetrics.projectPicker.stackSpacing) {
        ForEach(model.projectPickerFooter().items) { item in
          ProjectPickerFooterRow(item: item)
        }
      }
    }
    .padding(DesignMetrics.spacing.m)
    .frame(width: DesignMetrics.projectPicker.width)
    .onAppear { fieldFocused = true }
  }

  /// The rows as the view draws them: what each shows, what a click does,
  /// its ⋯ menu — the values the tests read.
  func rowViews(_ rows: [ProjectPickerRow]) -> [ProjectPickerRowView] {
    rows.map { row in
      ProjectPickerRowView(
        row: row,
        isHighlighted: row.id == model.projectPickerHighlight,
        choose: { [model] in model.chooseProject(row.slug) },
        hover: { [model] in model.highlightProjectPickerRow(row.id) },
        menu: row.slug.map { model.projectRowMenu(for: $0) })
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .pinaxCaption()
      .padding(.horizontal, DesignMetrics.spacing.xs)
      .padding(.vertical, DesignMetrics.spacing.xs)
  }
}

struct ProjectPickerRowView: View {
  let row: ProjectPickerRow
  let isHighlighted: Bool
  let choose: () -> Void
  /// The pointer moves the highlight, as in a menu.
  let hover: () -> Void
  /// nil on All Projects.
  let menu: ProjectRowMenu?
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      SidebarEntryIcon(
        systemImage: ProjectTitleItem.projectSymbol(row.slug), tint: .project)
      VStack(alignment: .leading, spacing: DesignMetrics.projectPicker.stackSpacing) {
        Text(row.name)
          .pinaxBody()
          .lineLimit(1)
        Text(row.detail)
          .pinaxSecondary()
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if let menu, isHovering {
        Menu {
          ForEach(menu.items) { item in
            ProjectPickerMenuButton(item: item)
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    .modifier(ProjectPickerRowChrome(isHighlighted: isHighlighted))
    .onTapGesture(perform: choose)
    .onHover { hovering in
      isHovering = hovering
      if hovering { hover() }
    }
  }
}

/// What every picker row shares — project rows and the footer's: the inset,
/// the full width as the hit area, the highlight behind.
struct ProjectPickerRowChrome: ViewModifier {
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, DesignMetrics.spacing.xs)
      .padding(.vertical, DesignMetrics.spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if isHighlighted {
          RoundedRectangle(cornerRadius: DesignMetrics.radius.chip).fill(.quaternary)
        }
      }
      .contentShape(Rectangle())
  }
}

/// New Project… and Manage Projects… as menu rows: the project rows' inset
/// and width, highlighted under the pointer.
struct ProjectPickerFooterRow: View {
  let item: ProjectRowMenu.Item
  @State private var isHovering = false
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button(action: perform) {
      Text(item.title)
        .pinaxBody()
        .modifier(ProjectPickerRowChrome(isHighlighted: isHovering && item.isEnabled))
    }
    .buttonStyle(.plain)
    .disabled(!item.isEnabled)
    .onHover { isHovering = $0 }
  }

  func perform() {
    item.action()
    if item.opensSettings { openSettings() }
  }
}

/// One `ProjectRowMenu` item as a button; the Settings ones open the
/// Settings window after their action, like `ProjectSettingsLinkButton`.
struct ProjectPickerMenuButton: View {
  let item: ProjectRowMenu.Item
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button(item.title) {
      item.action()
      if item.opensSettings { openSettings() }
    }
    .disabled(!item.isEnabled)
  }
}
