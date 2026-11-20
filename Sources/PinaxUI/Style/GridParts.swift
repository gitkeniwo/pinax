import SwiftUI

// The grid's parts, defined once here beside `PinaxParts.swift`.

extension SourceTint {
  /// PicGo is the orange caption square; Bucket takes Externals' aqua,
  /// since that is where bucket imports come from. The one source →
  /// hue map: the grid's square and the inspector's Source square read it.
  var token: PinaxPalette.Token {
    switch self {
    case .picgo: return .orange
    case .bucket: return .aqua
    // Copied in from another site.
    case .migrated: return .blue
    }
  }

  var color: Color { PinaxPalette.color(token) }
}

extension View {
  /// The metadata scrim: words on black 55 %, corner 5, padding 2 × 6.
  public func pinaxScrimChip() -> some View {
    self
      .pinaxScrimLabel()
      .lineLimit(1)
      .padding(.vertical, DesignMetrics.scrim.verticalPadding)
      .padding(.horizontal, DesignMetrics.scrim.horizontalPadding)
      .background(
        .black.opacity(DesignMetrics.scrim.opacity),
        in: RoundedRectangle(cornerRadius: DesignMetrics.scrim.radius, style: .continuous))
  }

  /// The caption date: on a selected cell, accentFill behind
  /// it, its plate reaching `gridCaption.datePlatePadding` past the text on
  /// the leading side. The padding is there in both states, so the text
  /// sits in the same place selected or not. The text's colour is the
  /// caller's (white when selected).
  public func pinaxSelectedDatePlate(_ isOn: Bool) -> some View {
    self
      .padding(.horizontal, DesignMetrics.gridCaption.datePlatePadding)
      .background {
        if isOn {
          RoundedRectangle(cornerRadius: DesignMetrics.radius.chip, style: .continuous)
            .fill(PinaxPalette.accentFill)
        }
      }
      .padding(.leading, -DesignMetrics.gridCaption.datePlatePadding)
  }

  /// The jump bar's current segment, on a count capsule (padding 1 × 7,
  /// corner 5, on the count ground).
  public func pinaxCurrentSegmentPlate() -> some View {
    self
      .padding(.vertical, DesignMetrics.jumpBar.currentVerticalPadding)
      .padding(.horizontal, DesignMetrics.jumpBar.currentHorizontalPadding)
      .background(
        PinaxPalette.count,
        in: RoundedRectangle(cornerRadius: DesignMetrics.jumpBar.currentRadius, style: .continuous))
  }
}

extension View {
  /// The jump bar's grouping switch. On, a soft plate behind it and the
  /// accent for its ink (20 high, padding 0 × 6, corner 5); off,
  /// nothing. The switch stays the system's toggle button; the padding is
  /// there both ways, so switching never moves the bar.
  public func pinaxSoftToggleBackground(_ isOn: Bool) -> some View {
    self
      .tint(PinaxPalette.accent)
      .padding(.horizontal, DesignMetrics.jumpBar.toggleHorizontalPadding)
      .frame(height: DesignMetrics.jumpBar.toggleHeight)
      .background {
        if isOn {
          RoundedRectangle(cornerRadius: DesignMetrics.jumpBar.toggleRadius, style: .continuous)
            .fill(PinaxPalette.soft)
        }
      }
  }
}
