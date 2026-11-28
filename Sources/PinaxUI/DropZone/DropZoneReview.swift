import SwiftUI

/// A reviewed card's switch: on sends the compressed copy, off the
/// original. Turned off and dimmed while the card is still being prepared,
/// and for good on a card with no copy to choose.
struct DropZoneReviewSwitch: View {
  let card: DropZoneModel.UploadCard
  @ObservedObject var model: DropZoneModel
  /// The List puts "Compress" beside it; the Shelf's capsule has no room.
  var showsLabel = true
  @Environment(\.colorScheme) private var colorScheme

  static let label = "Compress"

  /// What the switch shows: on only for a ready card set to its copy.
  static func isOn(_ card: DropZoneModel.UploadCard) -> Bool {
    guard case .review(let useOriginal) = card.phase else { return false }
    return card.canCompress && !useOriginal
  }

  static func isEnabled(_ card: DropZoneModel.UploadCard) -> Bool {
    card.phase.isReview && card.canCompress
  }

  var body: some View {
    let palette = DropZonePalette.of(colorScheme)
    let enabled = Self.isEnabled(card)
    HStack(spacing: DesignMetrics.dropZone.metaSpacing) {
      Toggle(
        Self.label,
        isOn: Binding(
          get: { Self.isOn(card) },
          set: { model.setCompresses(card.id, $0) })
      )
      .toggleStyle(.switch)
      // On in the app's teal, as the settings' switches.
      .tint(PinaxPalette.accentFill)
      .controlSize(.mini)
      .labelsHidden()
      if showsLabel {
        Text(Self.label)
          .foregroundStyle(palette.primary)
          .pinaxSecondary()
          .lineLimit(1)
      }
    }
    .disabled(!enabled)
    .opacity(enabled ? 1 : DesignMetrics.dropZone.reviewDimmedOpacity)
    .fixedSize()
    .help(Self.label)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(Self.label) \(card.filename)")
    .dropZoneLayout(.reviewSwitch, card: card.id)
  }
}

/// Review's bottom bar: the batch in numbers, Compress All / Use Originals,
/// Cancel (Esc) and Upload (Return).
struct DropZoneReviewBar: View {
  @ObservedObject var model: DropZoneModel
  /// The app's panel answers Esc and Return; the settings preview must not
  /// take them from the Settings window.
  let handlesKeys: Bool
  @Environment(\.colorScheme) private var colorScheme

  private typealias M = DesignMetrics.dropZone

  static let compressAll = "Compress All"
  static let useOriginals = "Use Originals"
  static let cancel = "Cancel"
  static let upload = "Upload"

  var body: some View {
    let palette = DropZonePalette.of(colorScheme)
    let summary = model.reviewSummary
    VStack(alignment: .leading, spacing: M.reviewBarGap) {
      totals(summary, palette)
      HStack(spacing: M.reviewButtonGap) {
        HStack(spacing: 0) {
          Button(Self.compressAll) { model.setAllCompress(true) }
            .disabled(!summary.canCompressAll)
          Rectangle()
            .fill(palette.rule)
            .frame(width: M.reviewBarRule, height: M.reviewButtonHeight - 10)
          Button(Self.useOriginals) { model.setAllCompress(false) }
            .disabled(!summary.canUseOriginals)
        }
        .buttonStyle(ReviewPairButtonStyle())
        .background(
          palette.buttonFill, in: RoundedRectangle(cornerRadius: M.reviewButtonRadius))
        .fixedSize()
        Spacer(minLength: 0)
        keyed(Button(Self.cancel) { model.cancelReview() }, .cancelAction)
          .buttonStyle(ReviewButtonStyle(isPrimary: false))
        keyed(Button(Self.upload) { model.uploadReviewed() }, .defaultAction)
          .buttonStyle(ReviewButtonStyle(isPrimary: true))
      }
    }
    .padding(.top, M.reviewBarTop)
    .padding([.horizontal, .bottom], M.panelInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      Rectangle().fill(palette.rule).frame(height: M.reviewBarRule)
    }
  }

  /// "4 images · 8.8 MB → 1.8 MB", the count in the primary ink.
  private func totals(_ summary: ReviewSummary, _ palette: DropZonePalette) -> some View {
    let count = Text(summary.countText).fontWeight(.semibold).foregroundStyle(palette.primary)
    let rest = String(summary.text.dropFirst(summary.countText.count))
    return Text("\(count)\(rest)")
      .foregroundStyle(palette.secondary)
      .pinaxSecondary()
      .monospacedDigit()
      .lineLimit(1)
      .help(summary.text)
  }

  @ViewBuilder
  private func keyed(_ button: some View, _ shortcut: KeyboardShortcut) -> some View {
    if handlesKeys {
      button.keyboardShortcut(shortcut)
    } else {
      button
    }
  }
}

/// Cancel and Upload: 24 pt high, a light ground; Upload in its deep green
/// with white words.
private struct ReviewButtonStyle: ButtonStyle {
  let isPrimary: Bool

  func makeBody(configuration: Configuration) -> some View {
    Face(configuration: configuration, isPrimary: isPrimary)
  }

  private struct Face: View {
    let configuration: Configuration
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      let palette = DropZonePalette.of(colorScheme)
      configuration.label
        .fontWeight(isPrimary ? .semibold : .regular)
        .foregroundStyle(isPrimary ? Color.white : palette.primary)
        .pinaxSecondary()
        .lineLimit(1)
        .padding(.horizontal, DesignMetrics.dropZone.reviewButtonPadding)
        .frame(height: DesignMetrics.dropZone.reviewButtonHeight)
        .background(
          isPrimary ? palette.primaryButton : palette.buttonFill,
          in: RoundedRectangle(cornerRadius: DesignMetrics.dropZone.reviewButtonRadius))
        .opacity(
          isEnabled ? (configuration.isPressed ? 0.7 : 1) : DesignMetrics.dropZone.reviewDimmedOpacity)
        .contentShape(Rectangle())
        .fixedSize()
    }
  }
}

/// One half of Compress All / Use Originals: words only, greyed when there
/// is nothing for it to change.
private struct ReviewPairButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Face(configuration: configuration)
  }

  private struct Face: View {
    let configuration: Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      configuration.label
        .foregroundStyle(DropZonePalette.of(colorScheme).primary)
        .pinaxCaption()
        .lineLimit(1)
        .padding(.horizontal, DesignMetrics.dropZone.reviewPairPadding)
        .frame(height: DesignMetrics.dropZone.reviewButtonHeight)
        .opacity(
          isEnabled ? (configuration.isPressed ? 0.6 : 1) : DesignMetrics.dropZone.reviewDimmedOpacity)
        .contentShape(Rectangle())
    }
  }
}
