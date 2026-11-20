import AppKit
import SwiftUI

/// The toolbar's ♥, Photos' favourite button. It is Edit ▸ Favorite
/// in another place — the same model call on the same selection, and the
/// same value for its state — so the key, the menu and this button cannot
/// disagree.
struct FavoriteToolbarButton: View {
  @ObservedObject var model: GalleryModel

  /// Filled only when every selected item is a favourite.
  var symbol: String {
    model.selectionIsFavorite ? "heart.fill" : "heart"
  }

  var title: String {
    model.selectionIsFavorite ? "Unfavorite" : "Favorite"
  }

  /// The button's action, named so tests drive exactly what the click does.
  func perform() async {
    await model.toggleFavoriteFromCommand()
  }

  var body: some View {
    Button {
      Task { await perform() }
    } label: {
      Label(title, systemImage: symbol)
    }
    .help(title)
    .disabled(!model.canCurateSelection)
  }
}

/// The toolbar's Share. The selection's original files — fetched
/// first when they are not cached — go to the system
/// share menu, which opens under this button once they are on disk.
struct ShareToolbarButton: View {
  @ObservedObject var model: GalleryModel

  static let symbol = "square.and.arrow.up"

  func perform() async {
    await model.shareSelection()
  }

  var body: some View {
    Button {
      Task { await perform() }
    } label: {
      Label("Share", systemImage: Self.symbol)
    }
    .help("Share")
    .background(ShareAnchor())
    .disabled(!model.canShareSelection)
  }
}

/// Where the system share menu opens: `NSSharingServicePicker` needs an
/// `NSView` to hang from, and a SwiftUI toolbar button does not expose one,
/// so this empty view sits behind the Share button and stands in for it.
struct ShareAnchor: NSViewRepresentable {
  @MainActor private static weak var anchor: NSView?

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    Self.anchor = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    Self.anchor = nsView
  }

  @MainActor static func present(_ urls: [URL]) {
    guard let view = anchor?.window != nil ? anchor : NSApp.keyWindow?.contentView else { return }
    NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
  }
}
