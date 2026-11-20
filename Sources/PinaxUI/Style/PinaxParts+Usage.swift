import AppKit
import SwiftUI

// Usage's parts, defined once here beside `PinaxParts.swift` and
// `GridParts.swift`. Shared parts (`ColorSquare`, `CountCapsule`,
// `ControlGroupCapsule`, `PinaxIconButtonStyle`, `pinaxSelectedDatePlate`)
// are used, not rebuilt.

/// Usage ▸ Images' reference count (`right:5px;top:5px;padding:2px 6px;
/// border-radius:5px;background:var(--ylwfill);color:#282828`, a 10 pt link
/// glyph 3 before the number). Shown only above one reference.
public struct UsageRefsBadge: View {
  let count: Int

  public init(count: Int) {
    self.count = count
  }

  public var body: some View {
    HStack(spacing: DesignMetrics.usageRefsBadge.spacing) {
      Image(systemName: "link")
        .pinaxGlyph(DesignMetrics.usageRefsBadge.glyph, weight: .bold)
      Text(count.formatted())
        .pinaxRefsBadge()
    }
    .foregroundStyle(PinaxPalette.refsBadgeInk)
    .padding(.vertical, DesignMetrics.usageRefsBadge.verticalPadding)
    .padding(.horizontal, DesignMetrics.usageRefsBadge.horizontalPadding)
    .background(
      PinaxPalette.yellow,
      in: RoundedRectangle(cornerRadius: DesignMetrics.usageRefsBadge.radius, style: .continuous))
  }
}

/// A reference's line, on a count capsule ("L21"; 1 pt by 6 pt padding,
/// corner 5).
public struct UsageLineBadge: View {
  let line: Int
  /// A fixed width with the number centred (Externals' 30); nil sizes the
  /// capsule to its text.
  let width: CGFloat?

  public init(line: Int, width: CGFloat? = nil) {
    self.line = line
    self.width = width
  }

  public var body: some View {
    Text("L\(line)")
      .pinaxCount()
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.vertical, DesignMetrics.usageLineBadge.verticalPadding)
      .padding(.horizontal, width == nil ? DesignMetrics.usageLineBadge.horizontalPadding : 0)
      .frame(width: width)
      .background(
        PinaxPalette.count,
        in: RoundedRectangle(cornerRadius: DesignMetrics.usageLineBadge.radius, style: .continuous))
  }
}

extension View {
  /// Usage's domain menu: a quiet pop-up —
  /// primary ink on the same grey ground as the Files | Images control,
  /// no tinted border; the menu, not the colour, says what is chosen.
  public func pinaxMenuCapsule() -> some View {
    self
      .pinaxOutlineCapsuleLabel()
      .foregroundStyle(.primary)
      .padding(.horizontal, DesignMetrics.usageOutlineCapsule.horizontalPadding)
      .frame(height: DesignMetrics.usageOutlineCapsule.height)
      .background { Capsule().fill(.quaternary) }
      .contentShape(Capsule())
  }
}

/// A clickable path segment (the file list's group headers and scope row,
/// Images' "Show in Files"): bare text at rest, the count plate under the
/// pointer or while pressed.
public struct UsageSegmentButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    UsageSegmentLabel(configuration: configuration)
  }

  private struct UsageSegmentLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .padding(.horizontal, DesignMetrics.usageRevision.segmentHorizontalPadding)
        .padding(.vertical, DesignMetrics.usageRevision.segmentVerticalPadding)
        .background {
          if hovering || configuration.isPressed {
            RoundedRectangle(cornerRadius: DesignMetrics.usageRevision.segmentRadius)
              .fill(PinaxPalette.count)
          }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
  }
}

extension ButtonStyle where Self == UsageSegmentButtonStyle {
  public static var usageSegment: UsageSegmentButtonStyle { UsageSegmentButtonStyle() }
}

/// Usage ▸ Files' list divider, kept with the parts so the gallery
/// sources stay free of hover state (AssetGridTests): a hairline in a 9 pt hit area that drags the
/// list's width between its bounds; on hover the column-resize cursor and
/// an accent grip.
struct UsageListDivider: View {
  @Binding var width: CGFloat
  @State private var hovering = false
  @State private var start: CGFloat?

  var body: some View {
    ZStack {
      Rectangle()
        .fill(hovering || start != nil ? AnyShapeStyle(PinaxPalette.accent) : AnyShapeStyle(.separator))
        .frame(
          width: hovering || start != nil
            ? DesignMetrics.usageRevision.dividerLineActive : DesignMetrics.usageRevision.dividerLine)
      if hovering || start != nil {
        Capsule()
          .fill(PinaxPalette.accent)
          .frame(
            width: DesignMetrics.usageRevision.gripWidth,
            height: DesignMetrics.usageRevision.gripHeight)
      }
    }
    .frame(width: DesignMetrics.usageRevision.dividerHitWidth)
    .padding(.horizontal, -(DesignMetrics.usageRevision.dividerHitWidth - DesignMetrics.usageRevision.dividerLine) / 2)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .zIndex(1)
    .onHover { inside in
      hovering = inside
      if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
    .gesture(
      DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { drag in
          let origin = start ?? width
          start = origin
          width = Self.clamped(origin + drag.translation.width)
        }
        .onEnded { _ in start = nil })
    .accessibilityHidden(true)
  }

  static func clamped(_ width: CGFloat) -> CGFloat {
    min(
      max(width, DesignMetrics.usageRevision.listMinWidth),
      DesignMetrics.usageRevision.listMaxWidth)
  }
}
