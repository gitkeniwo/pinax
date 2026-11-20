import CatalogCore
import Foundation
import SwiftUI

/// How a grid cell says where an image came from.
public enum SourceTagStyle: String, CaseIterable, Identifiable, Sendable {
  case dateLine
  case pill
  case dot
  case beforeName
  case off

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .dateLine: return "Date line"
    case .pill: return "Pill"
    case .dot: return "Dot"
    case .beforeName: return "Before name"
    case .off: return "Off"
    }
  }
}

/// The three zoom tiers of the caption (large 200 pt, medium 132 pt,
/// small 84 pt cells), read off the column count.
public enum SourceTier: Sendable, CaseIterable {
  case large, medium, small

  public init(columns: Int) {
    switch columns {
    case ...3: self = .large
    case 4...5: self = .medium
    default: self = .small
    }
  }
}

/// What colour role a source marker's icon, dot or square takes. The text
/// beside it is always `.secondary`. Its `color` is gruvbox and
/// lives in `Style/GridParts.swift`.
public enum SourceTint: Sendable, Equatable {
  case picgo
  case bucket
  case migrated
}

/// The one pure function behind every source marker in the grid. Pinax
/// uploads — and `otherImport` rows, which have no copy of their own yet —
/// are unmarked; `migrated` reads "Migrated".
struct SourceCaption: Equatable {
  enum Placement: Equatable {
    /// Rides on the date line: the date, then a 13 x 13 square at the
    /// line's end; the name is the hover text.
    case dateLine
    /// Its own row under the date, in a capsule.
    case pill
    /// Its own row under the date, a dot and the name.
    case dot
    /// Before the filename; with the filename off, at the start of the
    /// date line, icon only.
    case beforeFilename
    case beforeDate
  }

  var placement: Placement
  var icon: String?
  var tint: SourceTint
  /// The name beside the icon, when the tier and style have room for one.
  var text: String?
  /// The full name on hover when the visible text is shortened away.
  var help: String?

  static func tint(of source: AssetSource) -> SourceTint? {
    switch source {
    case .picgo: return .picgo
    case .bucket: return .bucket
    case .migrated: return .migrated
    case .pinax, .otherImport: return nil
    }
  }

  static func name(of source: AssetSource) -> String? {
    switch source {
    case .picgo: return "PicGo"
    case .bucket: return "Bucket"
    case .migrated: return "Migrated"
    case .pinax, .otherImport: return nil
    }
  }

  static func icon(of source: AssetSource) -> String? {
    switch source {
    case .picgo: return "photo.on.rectangle"
    case .bucket: return "cylinder"
    case .migrated: return "arrow.down.circle.fill"
    case .pinax, .otherImport: return nil
    }
  }

  /// Whether every cell under `style` carries a second row under the date,
  /// marked or not, so a row is the same height whatever it holds.
  static func reservesExtraRow(_ style: SourceTagStyle) -> Bool {
    style == .pill || style == .dot
  }

  /// `nil` when the cell shows no marker.
  static func make(
    style: SourceTagStyle, source: AssetSource, tier: SourceTier, showsFilename: Bool
  ) -> SourceCaption? {
    guard style != .off, let tint = tint(of: source), let icon = icon(of: source),
      let name = name(of: source)
    else { return nil }
    switch style {
    case .off:
      return nil
    case .dateLine:
      // Every tier draws only the square; the name is the hover.
      return SourceCaption(placement: .dateLine, icon: icon, tint: tint, text: nil, help: name)
    case .pill:
      return SourceCaption(placement: .pill, icon: icon, tint: tint, text: name, help: nil)
    case .dot:
      return SourceCaption(placement: .dot, icon: nil, tint: tint, text: name, help: nil)
    case .beforeName:
      return SourceCaption(
        placement: showsFilename ? .beforeFilename : .beforeDate,
        icon: icon, tint: tint, text: nil, help: name)
    }
  }
}
