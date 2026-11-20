import Foundation
import PinaxUI
import Testing

@Suite struct PinaxFormatTests {
  /// The shapes of ISO string the catalog actually stores: every timestamp in
  /// `Fixtures.swift` is the `...Z` form, and PicGo imports can carry an
  /// offset or fractional seconds instead.
  private let parseableISO = [
    "2026-01-01T00:00:00Z",
    "2026-03-03T14:05:00Z",
    "2026-08-20T13:00:01Z",
    "2026-03-03T14:05:00+08:00",
    "2026-03-03T14:05:00.123Z",
  ]

  @Test func formatsEveryStoredTimestampShape() {
    for iso in parseableISO {
      for style in [PinaxFormat.DateStyle.day, .dayTime, .month] {
        let formatted = PinaxFormat.date(iso, style: style)
        #expect(formatted != iso)
        #expect(!formatted.isEmpty)
      }
    }
  }

  /// Five locales: two field orders, two clocks, two scripts.
  private let localesUnderTest = ["en_US", "en_GB", "de_DE", "ja_JP", "zh_Hans_CN"]
  private let sample = "2026-03-03T14:05:00Z"

  @Test func dayTimeKeepsMinutesAtTwoDigitsInEveryLocale() throws {
    for id in localesUnderTest {
      let output = PinaxFormat.date(sample, style: .dayTime, locale: Locale(identifier: id))
      let time = try #require(
        output.firstMatch(of: #/([0-9]{1,2}):([0-9]+)/#), "\(id): \(output)")
      #expect(time.output.2.count == 2, "\(id): \(output)")
    }
  }

  @Test func dayTimeMarksAMPMWhereTheClockIsTwelveHour() {
    for id in localesUnderTest {
      let locale = Locale(identifier: id)
      guard locale.hourCycle == .oneToTwelve || locale.hourCycle == .zeroToEleven else { continue }
      let formatter = DateFormatter()
      formatter.locale = locale
      let output = PinaxFormat.date(sample, style: .dayTime, locale: locale)
      #expect(
        output.contains(formatter.amSymbol) || output.contains(formatter.pmSymbol),
        "\(id): \(output)")
    }
  }

  @Test func dayTimeContainsTheWholeDayStyleInEveryLocale() {
    for id in localesUnderTest {
      let locale = Locale(identifier: id)
      let day = PinaxFormat.date(sample, style: .day, locale: locale)
      let dayTime = PinaxFormat.date(sample, style: .dayTime, locale: locale)
      #expect(dayTime.contains(day), "\(id): \(dayTime) does not contain \(day)")
    }
  }

  @Test func returnsUnparseableTimestampsUnchanged() {
    #expect(PinaxFormat.date("garbage", style: .day) == "garbage")
    #expect(PinaxFormat.date("garbage", style: .dayTime) == "garbage")
    #expect(PinaxFormat.date("garbage", style: .month) == "garbage")
    #expect(PinaxFormat.date("", style: .day).isEmpty)
  }

  @Test func namesEveryImageMIMEWithoutEchoingIt() {
    for mime in ["image/png", "image/webp", "image/svg+xml"] {
      let kind = PinaxFormat.kind(mime: mime)
      #expect(!kind.isEmpty)
      #expect(kind != mime)
      #expect(!kind.contains("/"))
    }
  }

  @Test func derivesTheSelectionRingRadius() {
    #expect(
      DesignMetrics.selection.ringRadius
        == DesignMetrics.radius.thumbnail
          + DesignMetrics.selection.ringGap
          + DesignMetrics.selection.ringWidth)
  }

  @Test func splitsMonthBuckets() {
    let march = PinaxFormat.monthTitle("2026-03")
    #expect(march.month != "2026-03")
    #expect(march.year == "2026")
    #expect(PinaxFormat.monthTitle("garbage") == ("garbage", ""))
  }

  @Test func formatsCountsAndDimensions() {
    #expect(PinaxFormat.count(1, singular: "asset") == "1 asset")
    #expect(PinaxFormat.count(38, singular: "asset") == "38 assets")
    #expect(PinaxFormat.count(2, singular: "entry", plural: "entries") == "2 entries")
    #expect(PinaxFormat.dimensions(width: 1920, height: 1080) == "1920 × 1080")
    #expect(PinaxFormat.dimensions(width: nil, height: 1080) == nil)
    #expect(PinaxFormat.dimensions(width: 0, height: 0) == nil)
    #expect(!PinaxFormat.fileSize(1_200_000).isEmpty)
  }
}
