import AppKit
import SwiftUI

/// How the drop zone panel itself moves: the window appearing and going,
/// the drag-over layers, cards arriving and changing state, the review
/// bar. Every number lives here so the feel can be tuned in one place;
/// with Reduce Motion each animation is nil and every change is instant.
/// (`DropZoneMotion` is the status layer's own arc and glow.)
enum DropZonePanelMotion {
  // MARK: Window

  /// The panel fades in while sliding this far out of its corner.
  static let appearDuration: TimeInterval = 0.18
  static let appearSlide: CGFloat = 8
  /// It fades out, in place.
  static let disappearDuration: TimeInterval = 0.12

  // MARK: Surface

  /// A drag entering or leaving: blur, saturation, fade and scrim together.
  static let dragDuration: TimeInterval = 0.2
  /// A new card drops in from this far above while fading in.
  static let cardDrop: CGFloat = 10
  static let cardResponse: Double = 0.32
  static let cardDamping: Double = 0.82
  /// Cards of one batch land one after another, this far apart; past
  /// `staggeredCards` the rest land with the last.
  static let cardStagger: TimeInterval = 0.03
  static let staggeredCards = 8
  /// A phase change cross-fades the status (thumbnail ring, words); the
  /// card stays where it is.
  static let statusDuration: TimeInterval = 0.15
  /// The review bar rises this far as it fades in, with the window's timing.
  static let reviewBarSlide: CGFloat = 8

  // MARK: Settings preview replay

  /// The empty panel before the cards arrive, then how long each phase
  /// holds.
  static let replayLead: TimeInterval = 0.5
  static let replayWaiting: TimeInterval = 0.5
  static let replayCompressing: TimeInterval = 1.4
  static let replayUploading: TimeInterval = 1.6

  // MARK: Animations (nil: instant)

  static func appear(reducesMotion: Bool) -> Animation? {
    reducesMotion ? nil : .easeOut(duration: appearDuration)
  }

  static func disappear(reducesMotion: Bool) -> Animation? {
    reducesMotion ? nil : .easeIn(duration: disappearDuration)
  }

  static func drag(reducesMotion: Bool) -> Animation? {
    reducesMotion ? nil : .easeInOut(duration: dragDuration)
  }

  /// The `index`-th card from the top of a batch that just arrived.
  static func cardInsertion(index: Int, reducesMotion: Bool) -> Animation? {
    guard !reducesMotion else { return nil }
    return .spring(response: cardResponse, dampingFraction: cardDamping)
      .delay(Double(min(max(index, 0), staggeredCards)) * cardStagger)
  }

  /// The cards below moving down to make room, and a card leaving.
  static func cardShift(reducesMotion: Bool) -> Animation? {
    reducesMotion ? nil : .spring(response: cardResponse, dampingFraction: cardDamping)
  }

  static func status(reducesMotion: Bool) -> Animation? {
    reducesMotion ? nil : .easeInOut(duration: statusDuration)
  }

  /// The review bar showing uses the window's appear, going its disappear.
  static func reviewBar(showing: Bool, reducesMotion: Bool) -> Animation? {
    showing ? appear(reducesMotion: reducesMotion) : disappear(reducesMotion: reducesMotion)
  }

  static func cardTransition(index: Int, reducesMotion: Bool) -> AnyTransition {
    .asymmetric(
      insertion: .offset(y: -cardDrop).combined(with: .opacity)
        .animation(cardInsertion(index: index, reducesMotion: reducesMotion)),
      removal: .opacity)
  }

  static var reviewBarTransition: AnyTransition {
    .offset(y: reviewBarSlide).combined(with: .opacity)
  }

  /// Where the window starts before sliding into place: `appearSlide`
  /// toward its corner, diagonally (AppKit points, y up).
  static func appearOffset(corner: DropZoneCorner) -> CGVector {
    let step = appearSlide / 2.squareRoot()
    switch corner {
    case .topLeft: return CGVector(dx: -step, dy: step)
    case .topRight: return CGVector(dx: step, dy: step)
    case .bottomLeft: return CGVector(dx: -step, dy: -step)
    case .bottomRight: return CGVector(dx: step, dy: -step)
    }
  }

  /// The surface's motion as drawn, reported like `DropZoneMotion` for a
  /// hosted test: which changes animate.
  struct Report: Equatable {
    var dragFades: Bool
    var cardsSlideIn: Bool
    var statusFades: Bool
    var reviewBarSlides: Bool
  }

  /// The window's last show or hide, for a test: whether it animated.
  enum WindowChange: Equatable {
    case appeared(animated: Bool)
    case disappeared(animated: Bool)
  }
}

struct DropZonePanelMotionKey: PreferenceKey {
  static var defaultValue: DropZonePanelMotion.Report?
  static func reduce(
    value: inout DropZonePanelMotion.Report?, nextValue: () -> DropZonePanelMotion.Report?
  ) {
    value = nextValue() ?? value
  }
}
