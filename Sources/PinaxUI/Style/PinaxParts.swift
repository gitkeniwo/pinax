import SwiftUI

// The app's shared parts. Each is defined once here and only used
// elsewhere; each takes only the variants the design uses.

/// A white glyph or a few letters on a token-coloured rounded square:
/// sidebar rows' 20 pt square with corner 5, Catalog folders' and the
/// project letter's 18 / 5, the inspector header's 28 / 7 format square,
/// the grid caption's 13 / 3.5.
public struct ColorSquare: View {
  public enum Size: Sendable {
    case sidebar, folder, header, caption

    var side: CGFloat {
      switch self {
      case .sidebar: return DesignMetrics.colorSquare.sidebar
      case .folder: return DesignMetrics.colorSquare.folder
      case .header: return DesignMetrics.colorSquare.header
      case .caption: return DesignMetrics.colorSquare.caption
      }
    }

    var radius: CGFloat {
      switch self {
      case .sidebar: return DesignMetrics.colorSquare.sidebarRadius
      case .folder: return DesignMetrics.colorSquare.folderRadius
      case .header: return DesignMetrics.colorSquare.headerRadius
      case .caption: return DesignMetrics.colorSquare.captionRadius
      }
    }

    var glyph: CGFloat {
      switch self {
      case .sidebar: return DesignMetrics.colorSquare.sidebarGlyph
      case .folder, .header: return DesignMetrics.colorSquare.folderGlyph
      case .caption: return DesignMetrics.colorSquare.captionGlyph
      }
    }
  }

  public enum Content: Sendable {
    case symbol(String)
    case letters(String)
  }

  let size: Size
  let color: Color
  let content: Content
  /// A selected sidebar row's square wears a 1 pt white rim
  /// (`box-shadow:0 0 0 1px rgba(255,255,255,.55)`).
  let rimmed: Bool

  public init(size: Size, color: Color, content: Content, rimmed: Bool = false) {
    self.size = size
    self.color = color
    self.content = content
    self.rimmed = rimmed
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
    ZStack {
      shape.fill(color)
      switch content {
      case let .symbol(name):
        Image(systemName: name)
          .pinaxGlyph(size.glyph, weight: .semibold)
          .imageScale(.small)
      case let .letters(text):
        Text(text)
          .pinaxSquareLabel()
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
    }
    .foregroundStyle(.white)
    .frame(width: size.side, height: size.side)
    .overlay {
      if rimmed {
        shape
          .strokeBorder(
            .white.opacity(DesignMetrics.sidebarRow.selectedRimOpacity),
            lineWidth: DesignMetrics.sidebarRow.selectedRimWidth)
          .padding(-DesignMetrics.sidebarRow.selectedRimWidth)
      }
    }
  }
}

/// A format's square: its letters on its format colour
/// (the inspector header's `JPG` square, 28 × 28).
public struct FormatSquare: View {
  let mime: String
  let size: ColorSquare.Size

  public init(mime: String, size: ColorSquare.Size = .header) {
    self.mime = mime
    self.size = size
  }

  public var body: some View {
    ColorSquare(
      size: size, color: PinaxPalette.color(PinaxPalette.formatToken(mime: mime)),
      content: .letters(size == .caption ? "" : PinaxPalette.formatBadge(mime: mime)))
  }
}

/// A count in a capsule (padding 1 × 6, corner 9, on the count ground; on a
/// selected row, white 22 % with white text).
public struct CountCapsule: View {
  let count: Int
  let onAccent: Bool
  /// A fixed width with the number centred (the sidebar's 34); nil
  /// sizes the capsule to its number.
  let width: CGFloat?
  /// A corner radius; nil is the fully round capsule. A scope bar's segment
  /// count uses 5.
  let radius: CGFloat?

  public init(
    _ count: Int, onAccent: Bool = false, width: CGFloat? = nil, radius: CGFloat? = nil
  ) {
    self.count = count
    self.onAccent = onAccent
    self.width = width
    self.radius = radius
  }

  public var body: some View {
    Text(count.formatted())
      .pinaxCount()
      .lineLimit(1)
      .minimumScaleFactor(width == nil ? 1 : 0.75)
      .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .padding(.vertical, DesignMetrics.countCapsule.verticalPadding)
      .padding(.horizontal, width == nil ? DesignMetrics.countCapsule.horizontalPadding : 0)
      .frame(width: width)
      .background(
        onAccent
          ? AnyShapeStyle(.white.opacity(DesignMetrics.countCapsule.onAccentOpacity))
          : AnyShapeStyle(PinaxPalette.count),
        in: radius.map { AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous)) }
          ?? AnyShape(Capsule()))
  }
}

/// A line number in the table's Used In column ("L18"): 30 wide, centred,
/// corner 4, on the count ground.
public struct LineCapsule: View {
  let line: Int
  let onAccent: Bool
  let width: CGFloat

  public init(
    _ line: Int, onAccent: Bool = false,
    width: CGFloat = DesignMetrics.externalsTable.lineCapsuleWidth
  ) {
    self.line = line
    self.onAccent = onAccent
    self.width = width
  }

  public var body: some View {
    Text("L\(line)")
      .pinaxLineCapsule()
      .lineLimit(1)
      .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .padding(.vertical, DesignMetrics.externalsTable.lineCapsuleVerticalPadding)
      .frame(width: width)
      .background(
        onAccent
          ? AnyShapeStyle(.white.opacity(DesignMetrics.countCapsule.onAccentOpacity))
          : AnyShapeStyle(PinaxPalette.count),
        in: RoundedRectangle(
          cornerRadius: DesignMetrics.externalsTable.lineCapsuleRadius, style: .continuous))
  }
}

/// A square with a second copy of itself stacked behind (sidebar Catalog
/// rows, Externals domain rows): the back layer 3 right and
/// 3 up at the caller's opacity, parted from the front by a ring of the
/// ground it sits on. The front is the caller's own square.
public struct PinaxStackedSquare<Front: View>: View {
  let side: CGFloat
  let radius: CGFloat
  let backColor: Color
  let showsStack: Bool
  let stackOpacity: Double
  let ringColor: Color
  let ringWidth: CGFloat
  let offset: CGFloat
  let front: Front

  public init(
    side: CGFloat, radius: CGFloat, backColor: Color, showsStack: Bool,
    stackOpacity: Double, ringColor: Color, ringWidth: CGFloat, offset: CGFloat,
    @ViewBuilder front: () -> Front
  ) {
    self.side = side
    self.radius = radius
    self.backColor = backColor
    self.showsStack = showsStack
    self.stackOpacity = stackOpacity
    self.ringColor = ringColor
    self.ringWidth = ringWidth
    self.offset = offset
    self.front = front()
  }

  public var body: some View {
    ZStack {
      if showsStack {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(backColor.opacity(stackOpacity))
          .frame(width: side, height: side)
          .offset(x: offset, y: -offset)
        RoundedRectangle(cornerRadius: radius + ringWidth, style: .continuous)
          .fill(ringColor)
          .frame(width: side + 2 * ringWidth, height: side + 2 * ringWidth)
      }
      front
    }
    .frame(width: side, height: side)
  }
}

/// A tree line's elbow (sidebar, Externals): a vertical at `x`
/// from `startY` (in the row's coordinates) to the row's middle, an arc of
/// `radius`, then the horizontal to `endX`; `continues` runs the vertical on
/// to the row's bottom plus `overhang`, so a later sibling joins it.
public struct PinaxTreeElbow: Shape {
  public var x: CGFloat
  public var startY: CGFloat
  public var endX: CGFloat
  public var radius: CGFloat
  public var overhang: CGFloat
  public var continues: Bool

  public init(
    x: CGFloat, startY: CGFloat, endX: CGFloat, radius: CGFloat,
    overhang: CGFloat = 0, continues: Bool = false
  ) {
    self.x = x
    self.startY = startY
    self.endX = endX
    self.radius = radius
    self.overhang = overhang
    self.continues = continues
  }

  public func path(in rect: CGRect) -> Path {
    let middle = rect.midY
    let lineX = rect.minX + x
    let horizontalEnd = rect.minX + endX
    var path = Path()
    path.move(to: CGPoint(x: lineX, y: rect.minY + startY))
    path.addLine(to: CGPoint(x: lineX, y: middle - radius))
    path.addArc(
      center: CGPoint(x: lineX + radius, y: middle - radius), radius: radius,
      startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
    path.addLine(to: CGPoint(x: horizontalEnd, y: middle))
    if continues {
      path.move(to: CGPoint(x: lineX, y: middle - radius))
      path.addLine(to: CGPoint(x: lineX, y: rect.maxY + overhang))
    }
    return path
  }
}

/// A toolbar control group (26 high, corner 7, on the group ground), its
/// items split by `ControlGroupDivider`.
public struct ControlGroupCapsule<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    HStack(spacing: DesignMetrics.controlGroup.itemSpacing) {
      content
    }
    .padding(.horizontal, DesignMetrics.controlGroup.horizontalPadding)
    .frame(height: DesignMetrics.controlGroup.height)
    .background(
      PinaxPalette.grp,
      in: RoundedRectangle(cornerRadius: DesignMetrics.controlGroup.radius, style: .continuous))
  }
}

/// The rule between a control group's items (`width:1px;height:14px;
/// background:var(--sep)`).
public struct ControlGroupDivider: View {
  public init() {}

  public var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .frame(width: DesignMetrics.controlGroup.dividerWidth, height: DesignMetrics.controlGroup.dividerHeight)
  }
}

/// The inspector's collapsible section header: 22 high, corner 5, on the
/// band ground, 11.5 semibold, a 10 pt chevron. Opening and closing is
/// immediate: no animation.
public struct SectionBand: View {
  let title: String
  @Binding var isExpanded: Bool
  /// A figure at the band's trailing end (Usage's and Externals' Used In
  /// count); nil draws none.
  let trailing: String?

  public init(_ title: String, isExpanded: Binding<Bool>, trailing: String? = nil) {
    self.title = title
    self._isExpanded = isExpanded
    self.trailing = trailing
  }

  /// The chevron for a state: down when open, right when closed.
  public static func chevron(expanded: Bool) -> String {
    expanded ? "chevron.down" : "chevron.right"
  }

  public var body: some View {
    Button {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { isExpanded.toggle() }
    } label: {
      HStack(spacing: DesignMetrics.band.spacing) {
        Image(systemName: Self.chevron(expanded: isExpanded))
          .pinaxGlyph(DesignMetrics.band.chevron, weight: .bold)
          .frame(width: DesignMetrics.band.chevron)
        Text(title)
          .pinaxBandTitle()
          .lineLimit(1)
        Spacer(minLength: 0)
        if let trailing {
          Text(trailing)
            .pinaxBandCount()
            .lineLimit(1)
        }
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, DesignMetrics.band.horizontalPadding)
      .frame(height: DesignMetrics.band.height)
      .background(
        PinaxPalette.band,
        in: RoundedRectangle(cornerRadius: DesignMetrics.band.radius, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(.isHeader)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}

/// A 26 × 22 icon button on grp (the inspector link row's Copy link,
/// Download original, Open in browser). Set them `DesignMetrics.iconButton.spacing`
/// apart.
public struct PinaxIconButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .pinaxGlyph(DesignMetrics.iconButton.symbol)
      .foregroundStyle(.secondary)
      .frame(width: DesignMetrics.iconButton.width, height: DesignMetrics.iconButton.height)
      .background(
        PinaxPalette.grp,
        in: RoundedRectangle(cornerRadius: DesignMetrics.iconButton.radius, style: .continuous))
      .opacity(configuration.isPressed ? 0.6 : 1)
      .contentShape(Rectangle())
  }
}

extension ButtonStyle where Self == PinaxIconButtonStyle {
  public static var pinaxIcon: PinaxIconButtonStyle { PinaxIconButtonStyle() }
}

/// A figure on its hue's light ground (the size pill on purple, the
/// dimensions pill on blue; 28 high, corner 7, icon left,
/// figure right-aligned semibold).
public struct StatPill: View {
  public enum Tone: Sendable {
    /// Orange marks a large size; gray, what is not
    /// loaded.
    case purple, blue, orange, gray

    var token: PinaxPalette.Token {
      switch self {
      case .purple: .purple
      case .blue: .blue
      case .orange: .orange
      case .gray: .gray
      }
    }
  }

  let tone: Tone
  let systemImage: String
  let figure: String
  @Environment(\.colorScheme) private var colorScheme

  public init(_ figure: String, systemImage: String, tone: Tone) {
    self.figure = figure
    self.systemImage = systemImage
    self.tone = tone
  }

  public var body: some View {
    let dark = colorScheme == .dark
    let hue = PinaxPalette.value(tone.token, dark: dark)
    let ink = PinaxPalette.statInk(tone.token, dark: dark)
    HStack(spacing: DesignMetrics.statPill.spacing) {
      Image(systemName: systemImage)
        .pinaxGlyph(DesignMetrics.statPill.icon, weight: .semibold)
      Spacer(minLength: 0)
      Text(figure)
        .pinaxStatFigure()
        .lineLimit(1)
    }
    .foregroundStyle(Color(nsColor: ink.nsColor))
    .padding(.horizontal, DesignMetrics.statPill.horizontalPadding)
    .frame(height: DesignMetrics.statPill.height)
    .background(
      Color(nsColor: hue.nsColor).opacity(
        dark ? DesignMetrics.statPill.darkGround : DesignMetrics.statPill.lightGround),
      in: RoundedRectangle(cornerRadius: DesignMetrics.statPill.radius, style: .continuous))
  }
}

/// The accent's soft ground: the navigator switcher's selected quarter (22
/// high, corner 6) and the range bar's status capsule (22 high, padding
/// 0 × 9, corner 11, accent text 11.5 medium).
public struct SoftCapsule: View {
  let title: String
  let systemImage: String?

  public init(_ title: String, systemImage: String? = nil) {
    self.title = title
    self.systemImage = systemImage
  }

  public var body: some View {
    HStack(spacing: DesignMetrics.spacing.xs) {
      if let systemImage { Image(systemName: systemImage) }
      Text(title).lineLimit(1)
    }
    .pinaxCapsuleLabel()
    .foregroundStyle(PinaxPalette.accent)
    .padding(.horizontal, DesignMetrics.soft.capsuleHorizontalPadding)
    .frame(height: DesignMetrics.soft.capsuleHeight)
    .background(PinaxPalette.soft, in: Capsule())
  }
}

extension View {
  /// The navigator switcher's selected plate: soft ground, accent ink.
  public func pinaxSoftPlate(_ isOn: Bool) -> some View {
    self
      .foregroundStyle(isOn ? AnyShapeStyle(PinaxPalette.accent) : AnyShapeStyle(.secondary))
      .frame(maxWidth: .infinity)
      .frame(height: DesignMetrics.soft.plateHeight)
      .background {
        if isOn {
          RoundedRectangle(cornerRadius: DesignMetrics.soft.plateRadius, style: .continuous)
            .fill(PinaxPalette.soft)
        }
      }
  }
}

