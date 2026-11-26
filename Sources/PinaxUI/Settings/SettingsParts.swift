import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// A settings section's footer: its explanations, each a line, in
/// the secondary role.
struct SettingsFooter: View {
  let lines: [String]

  init(_ lines: String...) {
    self.lines = lines
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      ForEach(lines, id: \.self) { line in
        Text(line)
          .pinaxSecondary()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: Settings form parts
//
// The settings pages use only these.

/// A page's scrolling column of sections (`.body`).
struct SettingsPage<Content: View>: View {
  let content: Content
  /// Left of the sections: the title's inset, or less beside a list
  /// column's island (its 16 gap).
  var leadingInset = Metrics.pageInset
  /// The visible height, so the page's ground (and its click) reaches the
  /// bottom when the sections are shorter.
  @State private var viewportHeight: CGFloat = 0

  init(leadingInset: CGFloat = Metrics.pageInset, @ViewBuilder content: () -> Content) {
    self.leadingInset = leadingInset
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
        content
      }
      .padding(.leading, leadingInset)
      .padding(.trailing, Metrics.pageInset)
      .padding(.top, Metrics.pageTopInset)
      .padding(.bottom, Metrics.pageBottomInset)
      .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .topLeading)
      .background {
        // A click on the page's ground ends a field's editing, as a click
        // outside a field does in System Settings.
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { SettingsPage.endEditing() }
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
    // An ordinary page asks for the content area's width, not its longest
    // subtitle's one-line width; the window then wraps the subtitles in it.
    // A detail beside a list column is sized by its window.
    .frame(
      minWidth: 0, idealWidth: leadingInset == Metrics.pageInset ? Metrics.contentWidth : nil,
      maxWidth: .infinity)
  }

  /// Takes the focus from whatever field holds it, leaving the window
  /// first responder.
  static func endEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
  }
}

/// A row's switch (the system's, small), its title kept for
/// VoiceOver and for the tests that find it by name.
struct SettingsRowSwitch: View {
  let title: String
  @Binding var isOn: Bool

  init(_ title: String, isOn: Binding<Bool>) {
    self.title = title
    self._isOn = isOn
  }

  var body: some View {
    Toggle(title, isOn: $isOn)
      .labelsHidden()
      .toggleStyle(.switch)
      // On in the main window's teal, not the system accent.
      .tint(PinaxPalette.accentFill)
      .controlSize(.small)
  }
}

/// A row's pop-up, drawn as the grouped form's: the chosen value, then ⌃⌄
/// in a small gray box — never the accent fill a bare pop-up gets in a key
/// window. The choices are the picker's, inline in the menu, so the chosen
/// one keeps its checkmark; the picker is kept as a value for the tests
/// that read it.
struct SettingsMenuPicker<Value: Hashable, Choices: View, Label: View>: View {
  let title: String
  let picker: Picker<Text, Value, Choices>
  let label: Label

  init(
    _ title: String, selection: Binding<Value>, @ViewBuilder choices: () -> Choices,
    @ViewBuilder label: () -> Label
  ) {
    self.title = title
    self.picker = Picker(title, selection: selection, content: choices)
    self.label = label()
  }

  var body: some View {
    Menu {
      picker
        .labelsHidden()
        .pickerStyle(.inline)
    } label: {
      HStack(spacing: Metrics.popUpSpacing) {
        label
        Image(systemName: "chevron.up.chevron.down")
          .pinaxSettingsPopUpChevron()
          .frame(width: Metrics.popUpIndicatorWidth, height: Metrics.popUpIndicatorHeight)
          .background(
            PinaxPalette.Settings.popUpIndicator,
            in: RoundedRectangle(cornerRadius: Metrics.popUpIndicatorRadius, style: .continuous))
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(title)
  }
}

/// A section: its title, an optional note of up to two lines under it, and
/// its content — usually one `SettingsGroup`.
struct SettingsSection<Content: View>: View {
  let title: String
  let note: String?
  let content: Content

  init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.note = note
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.sectionInnerSpacing) {
      VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
        Text(title)
          .pinaxSettingsSectionTitle()
          .accessibilityAddTraits(.isHeader)
        if let note {
          Text(note)
            .pinaxSettingsSectionNote()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Metrics.sectionNoteMaxWidth, alignment: .leading)
        }
      }
      .padding(.leading, Metrics.sectionTitleInset)
      content
    }
  }
}

/// A group card (`.g`): the rows on the group ground, rounded, with a
/// hairline ring. Put a `SettingsRowDivider` between rows.
struct SettingsGroup<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PinaxPalette.Settings.group, in: shape)
    .overlay(shape.strokeBorder(PinaxPalette.Settings.groupRing, lineWidth: Metrics.groupRingWidth))
  }
}

/// The line between two rows of a group, starting at the rows' inset.
struct SettingsRowDivider: View {
  var body: some View {
    Rectangle()
      .fill(PinaxPalette.Settings.rowDivider)
      .frame(height: Metrics.rowDividerWidth)
      .padding(.leading, Metrics.rowHorizontalPadding)
  }
}

/// A row (`.r`): a title with an optional subtitle under it, and the
/// control at its trailing end. Top alignment (`.r.top`) is for a control
/// taller than one line.
struct SettingsRow<Trailing: View>: View {
  let title: String
  let subtitle: String?
  let alignment: VerticalAlignment
  let trailing: Trailing

  init(
    _ title: String, subtitle: String? = nil, alignment: VerticalAlignment = .center,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.alignment = alignment
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: alignment, spacing: Metrics.rowSpacing) {
      SettingsRowLabel(title: title, subtitle: subtitle)
      trailing
    }
    .padding(.vertical, Metrics.rowVerticalPadding)
    .padding(.horizontal, Metrics.rowHorizontalPadding)
    .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
  }
}

extension SettingsRow where Trailing == EmptyView {
  init(_ title: String, subtitle: String? = nil) {
    self.init(title, subtitle: subtitle) { EmptyView() }
  }
}

/// A row's title and subtitle, taking the row's spare width.
struct SettingsRowLabel: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.settings.rowSubtitleSpacing) {
      Text(title)
      if let subtitle {
        Text(subtitle)
          .pinaxSettingsRowSubtitle()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The card at the top of a page or a detail: an optional icon, a title,
/// a subtitle, and trailing controls. It is a group of its own.
struct SettingsHeaderCard<Icon: View, Trailing: View>: View {
  let title: String
  let subtitle: String?
  let icon: Icon
  let trailing: Trailing

  init(
    _ title: String, subtitle: String? = nil,
    @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon()
    self.trailing = trailing()
  }

  var body: some View {
    SettingsGroup {
      HStack(spacing: Metrics.headerSpacing) {
        icon
        VStack(alignment: .leading, spacing: Metrics.rowSubtitleSpacing) {
          Text(title).pinaxSettingsHeaderTitle()
          if let subtitle {
            Text(subtitle).pinaxSettingsRowSubtitle().monospacedDigit()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        trailing
      }
      .padding(.vertical, Metrics.headerVerticalPadding)
      .padding(.horizontal, Metrics.headerHorizontalPadding)
    }
  }
}

extension SettingsHeaderCard where Icon == EmptyView {
  init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
    self.init(title, subtitle: subtitle, icon: { EmptyView() }, trailing: trailing)
  }
}

/// Code in a row: a Copy format template, an include rule, a CLI
/// snippet, a key template. One line; a long one is cut at the end.
struct SettingsCodeChip: View {
  let code: String

  init(_ code: String) {
    self.code = code
  }

  var body: some View {
    Text(verbatim: code)
      .pinaxSettingsChip()
      .foregroundStyle(PinaxPalette.Settings.chipInk)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.vertical, Metrics.chipVerticalPadding)
      .padding(.horizontal, Metrics.chipHorizontalPadding)
      .background(PinaxPalette.Settings.chip, in: RoundedRectangle(cornerRadius: Metrics.chipRadius))
  }
}

/// A status in words: the status colour at 16 % behind ink-coloured
/// words, led by a dot in the status colour.
struct SettingsStatusPill: View {
  let text: String
  let status: PinaxPalette.SettingsStatus

  init(_ text: String, status: PinaxPalette.SettingsStatus) {
    self.text = text
    self.status = status
  }

  var body: some View {
    HStack(spacing: Metrics.pillSpacing) {
      Circle()
        .fill(PinaxPalette.color(status.token))
        .frame(width: Metrics.pillDotSize, height: Metrics.pillDotSize)
      Text(text)
    }
    .pinaxSettingsPill()
    .foregroundStyle(status.ink)
    .padding(.vertical, Metrics.pillVerticalPadding)
    .padding(.horizontal, Metrics.pillHorizontalPadding)
    .background(PinaxPalette.pillGround(status.token), in: Capsule())
  }
}

/// One choice of a + that opens a menu.
struct SettingsAddMenuItem: Identifiable {
  let title: String
  let action: () -> Void
  var id: String { title }
}

/// The + and − buttons under a list, then whatever the bar carries at its
/// trailing end (a hint, a scan time, a button).
struct SettingsAddRemoveBar<Trailing: View>: View {
  let addLabel: String
  let removeLabel: String
  let canRemove: Bool
  let onAdd: () -> Void
  /// With choices, + opens them and `onAdd` is not used.
  let addMenu: [SettingsAddMenuItem]
  let onRemove: () -> Void
  let trailing: Trailing

  init(
    add addLabel: String, remove removeLabel: String, canRemove: Bool,
    onAdd: @escaping () -> Void = {}, addMenu: [SettingsAddMenuItem] = [],
    onRemove: @escaping () -> Void,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.addLabel = addLabel
    self.removeLabel = removeLabel
    self.canRemove = canRemove
    self.onAdd = onAdd
    self.addMenu = addMenu
    self.onRemove = onRemove
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: Metrics.addRemoveBarSpacing) {
      SettingsAddRemoveButtons(
        addLabel: addLabel, removeLabel: removeLabel, canRemove: canRemove,
        onAdd: onAdd, addMenu: addMenu, onRemove: onRemove)
      Spacer(minLength: Metrics.rowSpacing)
      trailing
    }
    .padding(.vertical, Metrics.addRemoveBarVerticalPadding)
    .padding(.horizontal, Metrics.addRemoveBarHorizontalPadding)
    .frame(maxWidth: .infinity, minHeight: Metrics.addRemoveBarMinHeight)
  }
}

extension SettingsAddRemoveBar where Trailing == EmptyView {
  init(
    add addLabel: String, remove removeLabel: String, canRemove: Bool,
    onAdd: @escaping () -> Void, onRemove: @escaping () -> Void
  ) {
    self.init(
      add: addLabel, remove: removeLabel, canRemove: canRemove, onAdd: onAdd, onRemove: onRemove
    ) { EmptyView() }
  }
}

/// The bare + and − buttons, borderless. With
/// no `onRemove` there is no − (nothing in the app removes the item).
struct SettingsAddRemoveButtons: View {
  let addLabel: String
  let removeLabel: String
  var canAdd = true
  let canRemove: Bool
  let onAdd: () -> Void
  var addMenu: [SettingsAddMenuItem] = []
  let onRemove: (() -> Void)?

  var body: some View {
    HStack(spacing: DesignMetrics.settings.addRemoveBarSpacing) {
      add
        .accessibilityLabel(addLabel)
        .help(addLabel)
        .disabled(!canAdd)
      if let onRemove {
        Button(action: onRemove) { Image(systemName: "minus") }
          .accessibilityLabel(removeLabel)
          .help(removeLabel)
          .disabled(!canRemove)
      }
    }
    .buttonStyle(.borderless)
  }

  /// A button, or a menu that looks like it: no indicator.
  @ViewBuilder private var add: some View {
    if addMenu.isEmpty {
      Button(action: onAdd) { Image(systemName: "plus") }
    } else {
      Menu {
        ForEach(addMenu) { item in
          Button(item.title, action: item.action)
        }
      } label: {
        Image(systemName: "plus")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }
}

/// The list column of a list-and-detail page, as a floating island: a card
/// a level under the
/// detail's groups, one row per item — the page's icon, a name, a
/// subtitle — the selected row on the accent at 12 %, and + at the foot
/// (no − without `onRemove`). Its right edge drags its width, which each
/// page remembers; nothing is drawn there.
struct SettingsListColumn<ID: Hashable>: View {
  struct Row: Identifiable {
    let id: ID
    let name: String
    let subtitle: String?
  }

  let icon: SettingsTab
  let rows: [Row]
  @Binding var selection: ID?
  let addLabel: String
  let removeLabel: String
  var canAdd = true
  let onAdd: () -> Void
  let onRemove: (() -> Void)?

  @Environment(\.settingsDefaults) private var defaults
  /// The width while dragging and after; the remembered one until then.
  @State private var draggedWidth: CGFloat?
  @State private var dragStartWidth: CGFloat?

  /// The page's remembered width (`icon` is the page).
  var widthStore: SettingsListWidth { .page(icon, defaults: defaults) }

  var body: some View {
    VStack(spacing: DesignMetrics.spacing.none) {
      ScrollView {
        VStack(spacing: Metrics.islandRowSpacing) {
          ForEach(rows) { row in
            SettingsListColumnRow(
              icon: icon, name: row.name, subtitle: row.subtitle, isSelected: row.id == selection
            ) { selection = row.id }
          }
        }
        .padding(Metrics.islandPadding)
      }
      Rectangle()
        .fill(PinaxPalette.Settings.islandFooterDivider)
        .frame(height: Metrics.islandRingWidth)
      SettingsAddRemoveButtons(
        addLabel: addLabel, removeLabel: removeLabel, canAdd: canAdd, canRemove: selection != nil,
        onAdd: onAdd, onRemove: onRemove)
        .padding(.leading, Metrics.islandFooterLeadingPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.islandFooterHeight, alignment: .leading)
    }
    .frame(width: draggedWidth ?? widthStore.stored)
    .frame(maxHeight: .infinity)
    .background(
      PinaxPalette.Settings.island,
      in: RoundedRectangle(cornerRadius: Metrics.islandRadius, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: Metrics.islandRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Metrics.islandRadius, style: .continuous)
        .strokeBorder(PinaxPalette.Settings.islandRing, lineWidth: Metrics.islandRingWidth)
    }
    .overlay(alignment: .trailing) { resizeEdge }
    .padding(.leading, Metrics.islandLeadingInset)
    .padding(.top, Metrics.islandTopInset)
    .padding(.bottom, Metrics.islandBottomInset)
    // Above the detail, so the edge's outer half still takes the drag.
    .zIndex(1)
  }

  /// A strip astride the island's right edge: the resize cursor on hover,
  /// a drag that sets the width and remembers it on release.
  private var resizeEdge: some View {
    Color.clear
      .frame(width: Metrics.islandResizeHitWidth)
      .contentShape(Rectangle())
      .offset(x: Metrics.islandResizeHitWidth / 2)
      .onHover { inside in
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let start = dragStartWidth ?? draggedWidth ?? widthStore.stored
            dragStartWidth = start
            draggedWidth = SettingsListWidth.clamped(start + drag.translation.width)
          }
          .onEnded { _ in
            if let draggedWidth { widthStore.store(draggedWidth) }
            dragStartWidth = nil
          })
  }
}

/// One row of a list column.
struct SettingsListColumnRow: View {
  let icon: SettingsTab
  let name: String
  let subtitle: String?
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: Metrics.listRowIconSpacing) {
        SettingsIcon(kind: icon, size: Metrics.listRowIconSize)
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
          Text(name).lineLimit(1)
          if let subtitle {
            Text(subtitle).pinaxSettingsListSubtitle().lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, Metrics.islandRowHorizontalPadding)
      .frame(height: Metrics.islandRowHeight)
      .background(
        isSelected ? PinaxPalette.Settings.listSelection : Color.clear,
        in: RoundedRectangle(cornerRadius: Metrics.islandRowRadius, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
