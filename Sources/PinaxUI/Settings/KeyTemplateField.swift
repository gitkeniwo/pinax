import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings
private typealias Colors = PinaxPalette.KeyTemplateColors

/// How a token looks — a borderless rounded rect,
/// the hue only in its ground, the name without braces. The field, the
/// callouts and the Insert menu all draw it here.
enum KeyTemplateTokenArt {
  enum Size {
    case regular, small

    var height: CGFloat {
      self == .regular ? Metrics.keyTemplateTokenHeight : Metrics.keyTemplateSmallTokenHeight
    }

    var padding: CGFloat {
      self == .regular ? Metrics.keyTemplateTokenPadding : Metrics.keyTemplateSmallTokenPadding
    }

    var font: NSFont { self == .regular ? KeyTemplateFonts.token : KeyTemplateFonts.smallToken }
  }

  private static func attributes(_ size: Size, dark: Bool) -> [NSAttributedString.Key: Any] {
    [.font: size.font, .foregroundColor: Colors.text(dark: dark).nsColor]
  }

  /// The rounded rect alone, without the margins round it.
  static func size(_ placeholder: KeyTemplatePlaceholder, _ size: Size) -> NSSize {
    let name = placeholder.rawValue as NSString
    let width = name.size(withAttributes: attributes(size, dark: false)).width
    return NSSize(width: ceil(width) + 2 * size.padding, height: size.height)
  }

  static func draw(
    _ placeholder: KeyTemplatePlaceholder, _ size: Size, in rect: NSRect, dark: Bool
  ) {
    Colors.tokenGround(placeholder, dark: dark).nsColor.setFill()
    NSBezierPath(
      roundedRect: rect, xRadius: Metrics.keyTemplateTokenRadius,
      yRadius: Metrics.keyTemplateTokenRadius
    ).fill()
    let name = placeholder.rawValue as NSString
    let attributes = attributes(size, dark: dark)
    let textSize = name.size(withAttributes: attributes)
    name.draw(
      at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
      withAttributes: attributes)
  }

  /// The token as an image, for SwiftUI text (callouts) and menu items.
  static func image(_ placeholder: KeyTemplatePlaceholder, _ size: Size, dark: Bool) -> NSImage {
    let tokenSize = self.size(placeholder, size)
    let image = NSImage(size: tokenSize, flipped: false) { rect in
      draw(placeholder, size, in: rect, dark: dark)
      return true
    }
    image.accessibilityDescription = placeholder.rawValue
    return image
  }
}

/// A token in the field: one attachment character, so the cursor cannot
/// stop inside it and one delete takes it whole.
final class KeyTemplateTokenAttachment: NSTextAttachment {
  let placeholder: KeyTemplatePlaceholder

  init(_ placeholder: KeyTemplatePlaceholder) {
    self.placeholder = placeholder
    super.init(data: nil, ofType: nil)
    attachmentCell = KeyTemplateTokenCell(placeholder)
  }

  required init?(coder: NSCoder) { nil }
}

/// Draws the token in the field's own appearance, so it follows light and
/// dark without a cached image.
final class KeyTemplateTokenCell: NSTextAttachmentCell {
  let placeholder: KeyTemplatePlaceholder

  init(_ placeholder: KeyTemplatePlaceholder) {
    self.placeholder = placeholder
    super.init(textCell: "")
  }

  required init(coder: NSCoder) { fatalError("not coded") }

  override func cellSize() -> NSSize {
    let size = KeyTemplateTokenArt.size(placeholder, .regular)
    return NSSize(width: size.width + 2 * Metrics.keyTemplateTokenMargin, height: size.height)
  }

  /// Centred on the text's x-height band.
  override func cellBaselineOffset() -> NSPoint {
    let font = KeyTemplateFonts.field
    let middle = (font.ascender + font.descender) / 2
    return NSPoint(x: 0, y: (middle - Metrics.keyTemplateTokenHeight / 2).rounded())
  }

  override func wantsToTrackMouse() -> Bool { false }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    let appearance = controlView?.effectiveAppearance ?? NSAppearance.currentDrawing()
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let rect = cellFrame.insetBy(dx: Metrics.keyTemplateTokenMargin, dy: 0)
    KeyTemplateTokenArt.draw(placeholder, .regular, in: rect, dark: dark)
  }
}

/// The Key template field: a one-line text view whose
/// placeholders are tokens. Its text is the template with each token's
/// `{name}` read back; it re-parses after every edit through
/// `KeyTemplate.parts`, the parser keys are rendered with.
final class KeyTemplateTextView: NSTextView {
  var onSubmit: (() -> Void)?
  var onTemplateChange: ((String) -> Void)?
  var onCursorChange: ((Int?) -> Void)?
  var onFocusChange: ((Bool) -> Void)?

  /// The `{…}` that are not placeholders, in display (UTF-16) offsets.
  private(set) var invalidDisplayRanges: [NSRange] = []
  private var isRebuilding = false

  /// A text view on its own TextKit 1 stack (the token cells are TextKit 1),
  /// one line that scrolls sideways.
  static func make() -> KeyTemplateTextView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(
      size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = false
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = 1
    layout.addTextContainer(container)
    let view = KeyTemplateTextView(frame: .zero, textContainer: container)
    view.isRichText = true
    view.importsGraphics = false
    view.allowsUndo = false
    view.isEditable = true
    view.isSelectable = true
    view.drawsBackground = false
    // Vertically resizable between equal bounds: with it off, sizing to
    // the text collapses the frame to no height, and a click lands on the
    // clip view instead of the text.
    view.isHorizontallyResizable = true
    view.isVerticallyResizable = true
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: Metrics.keyTemplateFieldHeight)
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isContinuousSpellCheckingEnabled = false
    view.isGrammarCheckingEnabled = false
    view.smartInsertDeleteEnabled = false
    view.usesFindBar = false
    view.typingAttributes = textAttributes(.literal)
    view.setAccessibilityLabel("Key template")
    return view
  }

  private enum TextRole { case literal, invalid }

  private static func textAttributes(_ role: TextRole) -> [NSAttributedString.Key: Any] {
    [
      .font: KeyTemplateFonts.field,
      .foregroundColor: role == .literal ? Colors.literalNSColor : Colors.textNSColor,
    ]
  }

  // MARK: Template and cursor

  /// The template the field holds: each token read back as `{name}`.
  var template: String {
    get { Self.template(from: textStorage ?? NSTextStorage()) }
    set { rebuild(newValue, templateCursor: nil) }
  }

  /// The number of tokens drawn.
  var tokenCount: Int {
    var count = 0
    textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.utf16.count)) {
      value, _, _ in
      if value is KeyTemplateTokenAttachment { count += 1 }
    }
    return count
  }

  static func template(from text: NSAttributedString) -> String {
    var result = ""
    let string = text.string as NSString
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) {
      value, range, _ in
      if let token = value as? KeyTemplateTokenAttachment {
        result += String(repeating: token.placeholder.token, count: range.length)
      } else {
        result += string.substring(with: range)
      }
    }
    return result
  }

  /// The cursor as a UTF-16 offset into `template`.
  var templateCursor: Int? {
    templateOffset(forDisplay: selectedRange().location)
  }

  private func templateOffset(forDisplay location: Int) -> Int {
    guard let storage = textStorage else { return 0 }
    let prefix = storage.attributedSubstring(
      from: NSRange(location: 0, length: min(location, storage.length)))
    return (Self.template(from: prefix) as NSString).length
  }

  /// Rebuilds the text from `template`: tokens for placeholders, grey
  /// literals, invalid `{…}` in the text colour with a wavy line. The cursor
  /// keeps its place in the template (after a token it was inside).
  func set(template: String, templateCursor: Int?) {
    rebuild(template, templateCursor: templateCursor)
  }

  private func rebuild(_ template: String, templateCursor: Int?) {
    let text = NSMutableAttributedString()
    var invalid: [NSRange] = []
    var displayCursor: Int?
    for part in KeyTemplate.parts(of: template) {
      let range = NSRange(part.range, in: template)
      let start = text.length
      switch part.kind {
      case let .placeholder(placeholder):
        text.append(NSAttributedString(attachment: KeyTemplateTokenAttachment(placeholder)))
        text.addAttributes([.font: KeyTemplateFonts.field], range: NSRange(location: start, length: 1))
        if let cursor = templateCursor, displayCursor == nil, cursor >= range.location,
          cursor < NSMaxRange(range)
        {
          displayCursor = cursor == range.location ? start : start + 1
        }
      case .literal, .invalid:
        let role: TextRole = part.kind == .invalid ? .invalid : .literal
        text.append(NSAttributedString(string: String(template[part.range]), attributes: Self.textAttributes(role)))
        if part.kind == .invalid { invalid.append(NSRange(location: start, length: range.length)) }
        if let cursor = templateCursor, displayCursor == nil, cursor >= range.location,
          cursor < NSMaxRange(range)
        {
          displayCursor = start + cursor - range.location
        }
      }
    }
    isRebuilding = true
    textStorage?.setAttributedString(text)
    invalidDisplayRanges = invalid
    setSelectedRange(NSRange(location: displayCursor ?? text.length, length: 0))
    isRebuilding = false
    typingAttributes = Self.textAttributes(.literal)
    needsDisplay = true
  }

  // MARK: Editing

  override func didChangeText() {
    if !hasMarkedText() {
      rebuild(template, templateCursor: templateCursor)
    }
    super.didChangeText()
    onTemplateChange?(template)
  }

  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
  ) {
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    if !isRebuilding, !stillSelecting { onCursorChange?(templateCursor) }
  }

  override func insertNewline(_ sender: Any?) { onSubmit?() }
  override func insertLineBreak(_ sender: Any?) { onSubmit?() }
  override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
  override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocusChange?(true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { onFocusChange?(false) }
    return accepted
  }

  // MARK: Pasteboard

  /// Plain text only: a paste is re-read as a template, so `{name}` text
  /// pasted in becomes a token.
  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

  /// A copy carries the template text: a token copies as its `{name}`.
  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard let storage = textStorage else { return false }
    let range = selectedRange()
    guard range.length > 0 else { return false }
    pboard.clearContents()
    return pboard.setString(
      Self.template(from: storage.attributedSubstring(from: range)), forType: .string)
  }

  // MARK: Drawing

  /// The wavy red line under each `{…}` that is not a placeholder.
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let layoutManager, let textContainer, !invalidDisplayRanges.isEmpty else { return }
    let origin = textContainerOrigin
    Colors.errorRingNSColor.setStroke()
    for range in invalidDisplayRanges {
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      rect = rect.offsetBy(dx: origin.x, dy: origin.y)
      let font = KeyTemplateFonts.field
      let baseline = rect.minY + layoutManager.defaultBaselineOffset(for: font)
      let y = baseline - font.descender / 2 + Metrics.keyTemplateSquiggleOffset / 2
      let path = NSBezierPath()
      path.lineWidth = Metrics.keyTemplateSquiggleWidth
      var x = rect.minX
      var up = true
      path.move(to: NSPoint(x: x, y: y))
      while x < rect.maxX {
        x += Metrics.keyTemplateSquiggleStep
        path.line(to: NSPoint(x: x, y: y + (up ? -1 : 1) * Metrics.keyTemplateSquiggleAmplitude / 2))
        up.toggle()
      }
      path.stroke()
    }
  }
}

/// The field in SwiftUI. `template` and `cursor` are the editor's; a change
/// from outside (Insert, Reset) rebuilds the text, and `focusRequest`
/// bumps put the cursor back in the field.
struct KeyTemplateField: NSViewRepresentable {
  @Binding var template: String
  @Binding var cursor: Int?
  @Binding var isFocused: Bool
  /// The text's own width: the field less the Insert button inside it.
  var width: CGFloat
  var focusRequest: Int
  var onSubmit: () -> Void

  final class Coordinator {
    var parent: KeyTemplateField
    var focusRequest: Int

    init(_ parent: KeyTemplateField) {
      self.parent = parent
      self.focusRequest = parent.focusRequest
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = false
    scroll.borderType = .noBorder
    let text = KeyTemplateTextView.make()
    let inset = Metrics.keyTemplateFieldInset
    let lineHeight = text.layoutManager?.defaultLineHeight(for: KeyTemplateFonts.field) ?? 0
    text.textContainerInset = NSSize(
      width: inset, height: max(0, (Metrics.keyTemplateFieldHeight - lineHeight) / 2))
    // At least the field's width, so a click anywhere in it lands in the text.
    text.minSize = NSSize(width: width, height: Metrics.keyTemplateFieldHeight)
    text.frame = NSRect(origin: .zero, size: text.minSize)
    scroll.documentView = text
    text.template = template
    let coordinator = context.coordinator
    text.onTemplateChange = { coordinator.parent.template = $0 }
    text.onCursorChange = { coordinator.parent.cursor = $0 }
    text.onFocusChange = { coordinator.parent.isFocused = $0 }
    text.onSubmit = { coordinator.parent.onSubmit() }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let text = scroll.documentView as? KeyTemplateTextView else { return }
    if text.template != template {
      text.set(template: template, templateCursor: cursor)
    }
    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      text.window?.makeFirstResponder(text)
      if let cursor, text.template == template {
        text.set(template: template, templateCursor: cursor)
      }
    }
  }
}
