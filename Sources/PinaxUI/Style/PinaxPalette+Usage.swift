import AppKit
import SwiftUI

// Usage's reference-count badge. The yellow and the neutral grounds come
// from `PinaxPalette`; only the badge's fixed ink — `#282828`, readable on
// the yellow in both appearances — is new.

extension PinaxPalette {
  /// The reference badge's ink: `#282828` on the yellow fill.
  public static let refsBadgeInk = Color(
    nsColor: NSColor(srgbRed: 0x28 / 255, green: 0x28 / 255, blue: 0x28 / 255, alpha: 1))
}
