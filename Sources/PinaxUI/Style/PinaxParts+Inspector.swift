import SwiftUI

// The inspector's parts.

extension StatPill {
  /// The inspector's size pill: purple, a vertical double arrow.
  public static func size(_ figure: String) -> StatPill {
    StatPill(figure, systemImage: "arrow.up.and.down", tone: .purple)
  }

  /// A loaded image's size — orange from the large
  /// line up.
  public static func size(bytes: Int64) -> StatPill {
    StatPill(
      PinaxFormat.fileSize(bytes), systemImage: "arrow.up.and.down",
      tone: PinaxFormat.isLarge(bytes) ? .orange : .purple)
  }

  /// The inspector's dimensions pill: blue, a diagonal double arrow.
  public static func dimensions(_ figure: String) -> StatPill {
    StatPill(figure, systemImage: "arrow.up.left.and.arrow.down.right", tone: .blue)
  }
}

extension View {
  /// An inspector text field's face (the note and "+ Add tag…"):
  /// fieldbg, a 0.5 pt fieldline, corner 6; the line turns accent while the
  /// field has focus. The field inside is `.plain`.
  public func pinaxFieldChrome(
    focused: Bool, minHeight: CGFloat, horizontalPadding: CGFloat, verticalPadding: CGFloat = 0
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignMetrics.inspectorField.radius, style: .continuous)
    return self
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
      .background(PinaxPalette.fieldGround, in: shape)
      .overlay {
        shape.strokeBorder(
          focused ? AnyShapeStyle(PinaxPalette.accent) : AnyShapeStyle(PinaxPalette.fieldLine),
          lineWidth: focused
            ? DesignMetrics.inspectorField.focusedLineWidth : DesignMetrics.inspectorField.lineWidth)
      }
  }
}

/// A project's membership switch (the Projects row): a 34 × 18
/// green plate with a white check at its right when on; the count ground,
/// unmarked, when off. A click flips it.
public struct PinaxMembershipToggleStyle: ToggleStyle {
  @Environment(\.isEnabled) private var isEnabled

  public init() {}

  /// What the plate shows for a state: its fill and its mark.
  static func face(isOn: Bool) -> (fill: PinaxPalette.Token, mark: String?) {
    isOn ? (.green, "checkmark") : (.gray, nil)
  }

  public func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignMetrics.membershipSwitch.radius, style: .continuous)
    let face = Self.face(isOn: configuration.isOn)
    return ZStack(alignment: .trailing) {
      if configuration.isOn {
        shape.fill(PinaxPalette.color(face.fill))
      } else {
        shape.fill(PinaxPalette.count)
      }
      if let mark = face.mark {
        Image(systemName: mark)
          .pinaxGlyph(DesignMetrics.membershipSwitch.check, weight: .heavy)
          .foregroundStyle(.white)
          .padding(.trailing, DesignMetrics.membershipSwitch.checkInset)
      }
    }
    .frame(width: DesignMetrics.membershipSwitch.width, height: DesignMetrics.membershipSwitch.height)
    .opacity(isEnabled ? 1 : 0.5)
    .contentShape(shape)
    .onTapGesture {
      guard isEnabled else { return }
      configuration.isOn.toggle()
    }
    // Read by VoiceOver as the system switch it stands in for.
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}

extension ToggleStyle where Self == PinaxMembershipToggleStyle {
  public static var pinaxMembership: PinaxMembershipToggleStyle { PinaxMembershipToggleStyle() }
}

/// A pop-up menu's face on grp: its current choice and a small chevron
/// (22 high, padding 0 × 8, corner 6, 11.5 pt, a 10 pt chevron 3 after it).
/// The menu itself stays the system's `Menu`; this is only its label.
public struct PinaxPopupLabel: View {
  let title: String

  public init(_ title: String) {
    self.title = title
  }

  public var body: some View {
    HStack(spacing: DesignMetrics.inspectorLink.popupSpacing) {
      Text(title)
        .pinaxPopupLabel()
        .lineLimit(1)
      Image(systemName: "chevron.down")
        .pinaxGlyph(DesignMetrics.inspectorLink.popupChevron, weight: .bold)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, DesignMetrics.inspectorLink.popupHorizontalPadding)
    .frame(height: DesignMetrics.inspectorLink.popupHeight)
    .background(
      PinaxPalette.grp,
      in: RoundedRectangle(cornerRadius: DesignMetrics.inspectorLink.popupRadius, style: .continuous))
    .contentShape(Rectangle())
  }
}
