import AppKit
import SwiftUI

/// One gruvbox hue per sidebar category. Kept in `Style/` with the
/// palette: it is a table of colour values, like `LabelColor`.
extension SidebarIconTint {
  var token: PinaxPalette.Token {
    switch self {
    case .library: return .blue
    case .catalog: return .aqua
    // Its own colour (`color` below); the nearest token for anything that
    // asks for one.
    case .backendRoot: return .blue
    case .recent: return .orange
    case .favorites: return .red
    case .archived: return .gray
    case .overview: return .green
    case .usage: return .orange
    case .orphans: return .purple
    case .externals: return .aqua
    // No board: the inspector's project letter square is purple.
    case .project: return .purple
    // A project's folders and files are grey.
    case .projectSource: return .gray
    case .tag: return .yellow
    case let .label(label): return label.token
    }
  }

  var color: Color {
    self == .backendRoot ? Self.backendRootColor : PinaxPalette.color(token)
  }

  /// A steel blue no other row uses.
  static let backendRootColor = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x46 / 255, green: 0x73 / 255, blue: 0xA3 / 255, alpha: 1)
        : NSColor(srgbRed: 0x4F / 255, green: 0x7C / 255, blue: 0xAC / 255, alpha: 1)
    })
}
