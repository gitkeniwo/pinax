import CoreGraphics
@testable import PinaxUI
import Testing

/// The menu bar panel's page turn, as values: everything that moves is
/// worked out from one progress (0 the home page, 1 the Library page).
@Suite struct MenuBarMorphTests {
  static let card = CGRect(x: 10, y: 180, width: 320, height: 64)
  static let panel = CGRect(x: 0, y: 0, width: 340, height: 300)

  static func values(_ progress: CGFloat) -> MenuBarMorph.Values {
    MenuBarMorph.values(progress: progress, card: card, panel: panel)
  }

  /// Progress from 0 to 1 in 20 steps.
  static let steps: [CGFloat] = (0...20).map { CGFloat($0) / 20 }

  @Test("At rest: on the home page the platter is the card, the home page shown, the Library page not; on the Library page the reverse")
  func endpoints() {
    let home = Self.values(0)
    #expect(home.platter == Self.card)
    #expect(home.platterRadius == DesignMetrics.menuBarLibrary.cardRadius)
    #expect(home.platterBorder == 1)
    #expect(home.cardContent == 1)
    #expect(home.home == 1)
    #expect(home.homeScale == 1)
    #expect(home.library == 0)

    let library = Self.values(1)
    #expect(library.platter == Self.panel)
    #expect(library.platterRadius == DesignMetrics.menuBarLibrary.panelRadius)
    #expect(library.platterBorder == 0)
    #expect(library.cardContent == 0)
    #expect(library.home == 0)
    #expect(library.homeScale == DesignMetrics.menuBarLibrary.homeShrunkScale)
    #expect(library.library == 1)
  }

  @Test("Opening, the home page only fades, the Library page only appears, the platter only grows")
  func monotonic() {
    for (before, after) in zip(Self.steps, Self.steps.dropFirst()) {
      let a = Self.values(before)
      let b = Self.values(after)
      #expect(b.home <= a.home, "home at \(after)")
      #expect(b.cardContent <= a.cardContent, "card at \(after)")
      #expect(b.library >= a.library, "library at \(after)")
      #expect(b.platter.width >= a.platter.width, "width at \(after)")
      #expect(b.platter.height >= a.platter.height, "height at \(after)")
    }
  }

  @Test("Past either end, fades and the shrink hold their end values; the platter's frame goes past (the bounce)")
  func overshoot() {
    let under = Self.values(-0.05)
    let home = Self.values(0)
    #expect(under.home == home.home)
    #expect(under.cardContent == home.cardContent)
    #expect(under.library == home.library)
    #expect(under.homeScale == home.homeScale)
    #expect(under.platterBorder == home.platterBorder)
    #expect(under.platter.width < Self.card.width)
    #expect(under.platter.height < Self.card.height)

    let over = Self.values(1.05)
    let library = Self.values(1)
    #expect(over.home == library.home)
    #expect(over.cardContent == library.cardContent)
    #expect(over.library == library.library)
    #expect(over.homeScale == library.homeScale)
    #expect(over.platterBorder == library.platterBorder)
    #expect(over.platter.width > Self.panel.width)
    #expect(over.platter.height > Self.panel.height)
  }

  @Test("The two pages are never both showing: their opacities never add past 1.05, and one is gone before the other comes")
  func neverBothShowing() {
    let dense: [CGFloat] = (0...200).map { CGFloat($0) / 200 }
    for progress in dense {
      let values = Self.values(progress)
      #expect(values.home + values.library <= 1.05, "at \(progress)")
      #expect(min(values.home, values.library) <= 0.05, "at \(progress)")
    }
  }

  @Test("Below half way only the home page takes clicks; from half way only the Library page")
  func clicksGoToOnePage() {
    for progress in Self.steps + [-0.05, 1.05] {
      let values = Self.values(progress)
      #expect(values.homeTakesClicks == (progress < 0.5), "at \(progress)")
      #expect(values.libraryTakesClicks == (progress >= 0.5), "at \(progress)")
    }
  }
}
