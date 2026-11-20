import AppKit
import CatalogCore
import SwiftUI

/// Finder's seven labels in the app's gruvbox palette: the colour is the data —
/// a label *is* its colour — so this is a table of values; the names stay
/// Finder's.
extension AssetLabel {
  var token: PinaxPalette.Token {
    switch self {
    case .red: return .red
    case .orange: return .orange
    case .yellow: return .yellow
    case .green: return .green
    case .blue: return .blue
    case .purple: return .purple
    case .gray: return .gray
    }
  }

  var color: Color { PinaxPalette.color(token) }
}
