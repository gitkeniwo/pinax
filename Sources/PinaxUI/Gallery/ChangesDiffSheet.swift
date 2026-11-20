import AppKit
import SwiftUI

/// Show Changes…: a unified diff in a read-only `NSTextView` — monospaced,
/// selectable (⌘A / ⌘C), no wrapping, scrolling both ways. One view for
/// the external-image migration, the domain migration and the activity
/// panel. A SwiftUI `Text` laid the whole diff out at
/// once and went blank past the drawable size; the text view lays out
/// only what it shows.
struct ChangesDiffSheet: View {
  let text: String
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text("Changes")
        .pinaxTitle()
      ReadOnlyTextView(text: text)
        .background(PinaxPalette.band, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      HStack {
        Spacer()
        Button("Done", action: close)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: 720, height: 520)
    .onExitCommand(perform: close)
  }
}

/// A scrolling, read-only, unwrapped text view in the caption-size
/// monospaced font.
struct ReadOnlyTextView: NSViewRepresentable {
  let text: String

  static var font: NSFont {
    NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    guard let textView = scroll.documentView as? NSTextView else { return scroll }
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = Self.font
    textView.textColor = .labelColor
    textView.textContainerInset = NSSize(width: 6, height: 6)
    // No wrapping: the container is as wide as the longest line.
    textView.isHorizontallyResizable = true
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.string = text
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
    textView.string = text
  }
}
