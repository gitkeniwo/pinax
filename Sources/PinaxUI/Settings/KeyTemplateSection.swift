import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings
private typealias Colors = PinaxPalette.KeyTemplateColors

extension HorizontalAlignment {
  /// The field's leading edge: the example, the callout and the actions
  /// hang off it (`.sub`'s margin-left).
  fileprivate enum KeyTemplateFieldEdge: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.leading] }
  }

  fileprivate static let keyTemplateField = HorizontalAlignment(KeyTemplateFieldEdge.self)
}

/// The Key template row in Projects ▸ Storage, under
/// Key prefix — the token field with Insert at its end, and Set; then the
/// example key (or the error in its place), a warning, and Reset to
/// Default.
struct KeyTemplateBlock: View {
  let row: ProjectSettingsRow
  @ObservedObject var model: ProjectSettingsModel
  /// The Key prefix field as typed, which the example follows.
  let keyPrefix: String
  @State private var editor: KeyTemplateEditor
  @State private var isFocused = false
  @State private var focusRequest = 0
  @State private var isInsertOpen = false
  /// Set's width, so the lines under the field reach the row's end.
  @State private var setWidth: CGFloat = 0
  @State private var hoveredItem: KeyTemplatePlaceholder?
  /// The key card: shown while the pointer is on ⋯ or on the card, with
  /// how many folders the line kept before ⋯ (the rest are tinted).
  @State private var isCardShown = false
  @State private var isChipHovered = false
  @State private var isCardHovered = false
  @State private var keptFolders = 0
  @State private var cardTimer: Task<Void, Never>?
  @State private var didCopy = false
  @State private var isClockTipShown = false
  @State private var clockTimer: Task<Void, Never>?
  @Environment(\.colorScheme) private var colorScheme

  static let title = "Key template"
  static let insertTitle = "Insert"
  static let insertHeader = "Insert at cursor"
  static let insertHelp = "Insert a placeholder"
  static let keyLabel = "Key"
  static let cardTitle = "Example key"
  static let copyTitle = "Copy"
  static let copiedTitle = "Copied"
  static let resetTitle = "Reset to Default"

  init(row: ProjectSettingsRow, keyPrefix: String, model: ProjectSettingsModel) {
    self.row = row
    self.keyPrefix = keyPrefix
    self.model = model
    _editor = State(initialValue: KeyTemplateEditor(stored: row.keyTemplate, keyPrefix: keyPrefix))
  }

  var body: some View {
    VStack(alignment: .keyTemplateField, spacing: Metrics.keyTemplateLineSpacing) {
      HStack(spacing: Metrics.rowSpacing) {
        SettingsRowLabel(title: Self.title, subtitle: nil)
        field
          .alignmentGuide(.keyTemplateField) { $0[.leading] }
        Button("Set", action: submit)
          .disabled(!editor.canSet)
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { setWidth = $0 }
      }
      VStack(alignment: .leading, spacing: Metrics.keyTemplateLineSpacing) {
        if let path = editor.examplePath {
          exampleLine(path)
        }
        if let callout = editor.callout {
          calloutBox(callout)
            .frame(width: Metrics.keyTemplateFieldWidth)
        }
        if editor.showsReset {
          Button(Self.resetTitle, action: reset)
            .buttonStyle(.plain)
            .pinaxKeyTemplateLink()
            .foregroundStyle(Colors.linkColor)
        }
      }
      // The example may run on under Set to the row's end; the callout
      // keeps to the field's width.
      .frame(width: Metrics.keyTemplateFieldWidth + Metrics.rowSpacing + setWidth, alignment: .leading)
      .alignmentGuide(.keyTemplateField) { $0[.leading] }
    }
    .padding(.top, Metrics.keyTemplateTopPadding)
    .padding(.bottom, Metrics.keyTemplateBottomPadding)
    .padding(.horizontal, Metrics.rowHorizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: keyPrefix) { editor.keyPrefix = keyPrefix }
  }

  // MARK: Field

  private var field: some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.keyTemplateFieldRadius)
    let ring: Color? =
      editor.callout?.kind == .error ? Colors.errorRingColor : isFocused ? PinaxPalette.accentFill : nil
    let textWidth =
      Metrics.keyTemplateFieldWidth - Metrics.keyTemplateInsertWidth - Metrics.keyTemplateFieldBorderWidth
    return HStack(spacing: DesignMetrics.spacing.none) {
      KeyTemplateField(
        template: $editor.draft, cursor: $editor.cursor, isFocused: $isFocused,
        width: textWidth, focusRequest: focusRequest, onSubmit: submit
      )
      .frame(width: textWidth, height: Metrics.keyTemplateFieldHeight)
      Rectangle()
        .fill(Colors.fieldBorderColor)
        .frame(width: Metrics.keyTemplateFieldBorderWidth)
      insertButton
    }
    .frame(width: Metrics.keyTemplateFieldWidth, height: Metrics.keyTemplateFieldHeight, alignment: .leading)
    .clipShape(shape)
    .background(Colors.fieldGroundColor, in: shape)
    .overlay {
      shape.strokeBorder(Colors.fieldBorderColor, lineWidth: Metrics.keyTemplateFieldBorderWidth)
        .allowsHitTesting(false)
    }
    .overlay {
      if let ring {
        shape.strokeBorder(ring, lineWidth: Metrics.keyTemplateRingWidth)
          .allowsHitTesting(false)
      }
    }
  }

  // MARK: Under the field

  /// The example in a capsule — "Key", the path in one
  /// ink with faint slashes and the file semibold, then the clock when its
  /// dates are UTC's. Cut, it keeps the file whole and folds the middle
  /// folders into ⋯, whose card shows the whole key.
  private func exampleLine(_ path: KeyTemplateEditor.ExamplePath) -> some View {
    HStack(spacing: Metrics.keyTemplatePillSpacing) {
      Text(Self.keyLabel)
        .pinaxKeyTemplatePillLabel()
        .foregroundStyle(Colors.literalColor)
        .padding(.trailing, Metrics.keyTemplatePillLabelGap)
        .fixedSize()
      // Whole; the first folder kept and the rest folded; all folded.
      ViewThatFits(in: .horizontal) {
        pathLine(path, kept: nil)
        if path.folders.count > 1 { pathLine(path, kept: 1) }
        pathLine(path, kept: 0)
      }
      if let note = editor.utcNote {
        clock(note)
      }
    }
    .padding(.horizontal, Metrics.keyTemplatePillPadding)
    .frame(height: Metrics.keyTemplatePillHeight)
    .background(Capsule().fill(Colors.pillGroundColor))
    .overlay {
      Capsule()
        .strokeBorder(Colors.pillEdgeColor, lineWidth: Metrics.keyTemplatePillEdgeWidth)
        .allowsHitTesting(false)
    }
    .overlay {
      Capsule()
        .strokeBorder(
          LinearGradient(colors: [Colors.pillLightColor, .clear], startPoint: .top, endPoint: .center),
          lineWidth: Metrics.keyTemplatePillEdgeWidth
        )
        .allowsHitTesting(false)
    }
    .popover(isPresented: $isCardShown, arrowEdge: .bottom) { keyCard(path) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(Self.cardTitle): \(path.text)")
  }

  /// The path with `kept` folders before ⋯ (nil: every folder, no ⋯).
  private func pathLine(_ path: KeyTemplateEditor.ExamplePath, kept: Int?) -> some View {
    let folders = kept.map { Array(path.folders.prefix($0)) } ?? path.folders
    let folds = kept.map { $0 < path.folders.count } ?? false
    return HStack(spacing: Metrics.keyTemplatePathSpacing) {
      ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
        Text(verbatim: folder).font(KeyTemplateFonts.path).fixedSize()
        slash
      }
      if folds, let kept {
        chip(kept: kept)
        slash
      }
      Text(verbatim: path.file)
        .font(KeyTemplateFonts.pathFile)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .foregroundStyle(Colors.textColor)
  }

  private var slash: some View {
    Text(verbatim: "/")
      .font(KeyTemplateFonts.path)
      .opacity(Metrics.keyTemplateSlashOpacity)
  }

  /// ⋯: the folded folders. Resting on it opens the key card; a click
  /// opens it at once.
  private func chip(kept: Int) -> some View {
    Text(verbatim: "⋯")
      .pinaxKeyTemplatePillLabel()
      .padding(.horizontal, Metrics.keyTemplateChipPadding)
      .frame(height: Metrics.keyTemplateChipHeight)
      .background(
        Capsule().fill(isCardShown ? Colors.insertGroundColor : Colors.chipGroundColor))
      .contentShape(Capsule())
      .onHover { inside in
        isChipHovered = inside
        if inside { keptFolders = kept }
        scheduleCard(open: inside)
      }
      .onTapGesture {
        keptFolders = kept
        isCardShown = true
      }
  }

  /// A clock whose tip says the example's dates are UTC's, and which.
  private func clock(_ note: String) -> some View {
    Image(systemName: "clock")
      .pinaxKeyTemplateClock()
      .foregroundStyle(Colors.literalColor)
      .frame(width: Metrics.keyTemplateClockSize, height: Metrics.keyTemplateClockSize)
      .contentShape(Rectangle())
      .onHover { inside in
        clockTimer?.cancel()
        guard inside else {
          isClockTipShown = false
          return
        }
        clockTimer = Task {
          try? await Task.sleep(for: .seconds(Metrics.keyTemplateTipDelay))
          if !Task.isCancelled { isClockTipShown = true }
        }
      }
      .popover(isPresented: $isClockTipShown, arrowEdge: .bottom) {
        Text(note)
          .pinaxKeyTemplateSmall()
          .padding(.horizontal, Metrics.keyTemplateTipHorizontalPadding)
          .padding(.vertical, Metrics.keyTemplateTipVerticalPadding)
          .fixedSize()
      }
      .accessibilityLabel(note)
  }

  // MARK: Key card

  /// C-1: "Example key" and Copy, the whole key wrapping with the folded
  /// folders tinted, then what the example is of and its dates.
  private func keyCard(_ path: KeyTemplateEditor.ExamplePath) -> some View {
    VStack(alignment: .leading, spacing: Metrics.keyTemplateCardSpacing) {
      HStack {
        Text(Self.cardTitle)
          .pinaxKeyTemplateCardHeader()
          .foregroundStyle(.secondary)
        Spacer(minLength: DesignMetrics.spacing.none)
        Button {
          copy(path.text)
        } label: {
          HStack(spacing: Metrics.keyTemplateCopySpacing) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            Text(didCopy ? Self.copiedTitle : Self.copyTitle)
          }
          .pinaxKeyTemplateSmall()
          .foregroundStyle(Colors.insertTextColor)
          .padding(.horizontal, Metrics.keyTemplateCopyPadding)
          .padding(.vertical, Metrics.keyTemplateCopyVerticalPadding)
          .background(Capsule().fill(Colors.insertGroundColor))
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
      Text(cardKey(path))
        .lineSpacing(Metrics.keyTemplateCardKeyLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Rectangle()
        .fill(Colors.fieldBorderColor)
        .frame(height: Metrics.keyTemplateCardRuleHeight)
      Text(editor.sampleNote)
        .pinaxKeyTemplateSmall()
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Metrics.keyTemplateCardHorizontalPadding)
    .padding(.top, Metrics.keyTemplateCardTopPadding)
    .padding(.bottom, Metrics.keyTemplateCardBottomPadding)
    .frame(width: Metrics.keyTemplateCardWidth, alignment: .leading)
    .onHover { inside in
      isCardHovered = inside
      scheduleCard(open: false)
    }
  }

  /// The key in one ink, slashes faint, the file semibold, and the folders
  /// the line folded on the band's tint.
  private func cardKey(_ path: KeyTemplateEditor.ExamplePath) -> AttributedString {
    var key = AttributedString()
    var slash = AttributedString("/")
    slash.foregroundColor = Colors.textColor.opacity(Metrics.keyTemplateSlashOpacity)
    for (index, folder) in path.folders.enumerated() {
      var part = AttributedString(folder)
      if index >= keptFolders { part.backgroundColor = Colors.insertGroundColor }
      key += part + slash
    }
    var file = AttributedString(path.file)
    file.font = KeyTemplateFonts.cardKeyFile
    key += file
    var base = AttributeContainer()
    base.font = KeyTemplateFonts.cardKey
    base.foregroundColor = Colors.textColor
    return key.mergingAttributes(base, mergePolicy: .keepCurrent)
  }

  /// Opens the card after a rest on ⋯; closes it once the pointer has left
  /// both ⋯ and the card a moment.
  private func scheduleCard(open: Bool) {
    cardTimer?.cancel()
    cardTimer = Task {
      try? await Task.sleep(
        for: .seconds(open ? Metrics.keyTemplateCardOpenDelay : Metrics.keyTemplateCardCloseDelay))
      guard !Task.isCancelled else { return }
      if open {
        isCardShown = true
      } else if !isChipHovered && !isCardHovered {
        isCardShown = false
        didCopy = false
      }
    }
  }

  private func copy(_ key: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(key, forType: .string)
    didCopy = true
  }

  /// One message, its placeholders drawn as small tokens.
  private func calloutBox(_ callout: KeyTemplateEditor.Callout) -> some View {
    let error = callout.kind == .error
    return HStack(alignment: .top, spacing: Metrics.keyTemplateCalloutSpacing) {
      Image(systemName: error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
        .symbolRenderingMode(.palette)
        .foregroundStyle(PinaxPalette.statusGlyph, error ? Colors.errorIcon : Colors.warningIcon)
        .pinaxKeyTemplateCalloutIcon()
      calloutText(callout.issue.message)
        .pinaxKeyTemplateCallout()
        .foregroundStyle(error ? Colors.errorText : Colors.warningText)
        .lineSpacing(Metrics.keyTemplateCalloutLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, Metrics.keyTemplateCalloutVerticalPadding)
    .padding(.horizontal, Metrics.keyTemplateCalloutHorizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      error ? Colors.errorGround : Colors.warningGround,
      in: RoundedRectangle(cornerRadius: Metrics.keyTemplateCalloutRadius))
  }

  private func calloutText(_ message: String) -> Text {
    KeyTemplate.parts(of: message).reduce(Text(verbatim: "")) { text, part in
      if case let .placeholder(placeholder) = part.kind {
        let image = KeyTemplateTokenArt.image(placeholder, .small, dark: colorScheme == .dark)
        return text + Text(Image(nsImage: image)).baselineOffset(Metrics.keyTemplateCalloutTokenBaseline)
      }
      return text + Text(verbatim: String(message[part.range]))
    }
  }

  // MARK: Insert

  /// Insert: the braces in a segment at the field's end, opening the
  /// placeholders with their sample values — a popover, not a native menu,
  /// so the row under the pointer is the teal, not the system accent.
  private var insertButton: some View {
    Button {
      isInsertOpen.toggle()
    } label: {
      Image(systemName: "curlybraces")
        .pinaxKeyTemplateInsert()
        .foregroundStyle(.secondary)
        .frame(width: Metrics.keyTemplateInsertWidth, height: Metrics.keyTemplateFieldHeight)
        .background(isInsertOpen ? Colors.insertOpenGroundColor : Color.clear)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(Self.insertHelp)
    .accessibilityLabel(Self.insertTitle)
    .popover(isPresented: $isInsertOpen, arrowEdge: .bottom) { insertList }
  }

  private var insertList: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      Text(Self.insertHeader)
        .pinaxKeyTemplateMenuHeader()
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.keyTemplateMenuRowPadding)
        .frame(height: Metrics.keyTemplateMenuRowHeight, alignment: .bottomLeading)
      ForEach(KeyTemplateEditor.insertMenu(keyPrefix: editor.keyPrefix, date: editor.date)) { item in
        insertRow(item)
      }
    }
    .padding(Metrics.keyTemplateMenuPadding)
    .frame(width: Metrics.keyTemplateMenuWidth)
  }

  private func insertRow(_ item: KeyTemplateEditor.InsertItem) -> some View {
    let hovered = hoveredItem == item.placeholder
    return Button {
      isInsertOpen = false
      insert(item.placeholder)
    } label: {
      HStack(spacing: Metrics.keyTemplateMenuRowSpacing) {
        Image(nsImage: KeyTemplateTokenArt.image(item.placeholder, .regular, dark: colorScheme == .dark))
        Spacer(minLength: DesignMetrics.spacing.none)
        if let sample = item.sample {
          Text(verbatim: sample)
            .pinaxKeyTemplateMenuSample()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, Metrics.keyTemplateMenuRowPadding)
      .frame(height: Metrics.keyTemplateMenuRowHeight)
      .background {
        if hovered {
          RoundedRectangle(cornerRadius: Metrics.keyTemplateMenuRowRadius)
            .fill(Colors.menuHoverColor)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in
      if inside {
        hoveredItem = item.placeholder
      } else if hoveredItem == item.placeholder {
        hoveredItem = nil
      }
    }
    .accessibilityLabel([item.placeholder.rawValue, item.sample].compactMap { $0 }.joined(separator: " "))
  }

  private func submit() {
    editor.submit(to: model, project: row.slug)
  }

  private func insert(_ placeholder: KeyTemplatePlaceholder) {
    editor.insert(placeholder)
    focusRequest += 1
  }

  private func reset() {
    editor.reset(to: model, project: row.slug)
  }
}
