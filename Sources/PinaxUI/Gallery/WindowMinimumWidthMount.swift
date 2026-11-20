import AppKit
import SwiftUI

/// The AppKit half of the window's two-layer minimum width: one `widthAnchor >= width` constraint on the window's content view.
/// This is the window's real floor; SwiftUI's own minimum
/// (`GalleryWidthBudget.contentMinWidth`) follows the visible columns and
/// drops below it when a side column is closed.
///
/// Why a constraint and not `NSWindow.contentMinSize` / `minSize`: SwiftUI
/// owns those two and writes its own minimum straight back over any value
/// set on them (measured in the running app). The constraint is left alone,
/// and it does not feed into the check SwiftUI makes before expanding a side
/// column, which reads SwiftUI's minimum only.
///
/// Idempotent: `updateNSView` runs on every model publish, and the installer
/// finds its constraint by identifier rather than adding a second one.
struct WindowMinimumWidthMount: NSViewRepresentable {
  static let identifier = "PinaxWindowMinimumWidth"

  let width: CGFloat

  func makeNSView(context: Context) -> NSView {
    let view = Installer(frame: .zero)
    view.width = width
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let installer = nsView as? Installer else { return }
    installer.width = width
    installer.install()
  }

  final class Installer: NSView {
    var width: CGFloat = 0

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      install()
    }

    func install() {
      guard let contentView = window?.contentView else { return }
      if let floor = contentView.constraints.first(where: {
        $0.identifier == WindowMinimumWidthMount.identifier
      }) {
        floor.constant = width
        return
      }
      let floor = contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
      floor.identifier = WindowMinimumWidthMount.identifier
      floor.isActive = true
    }
  }
}
