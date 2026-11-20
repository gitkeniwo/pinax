import Foundation
import UniformTypeIdentifiers

/// Every string a view shows a number or a date as comes from here. Pure
/// functions, no state, so each one is directly testable.
public enum PinaxFormat {
  /// How much of a timestamp to show.
  public enum DateStyle {
    /// "Mar 3, 2026"
    case day
    /// "Mar 3, 2026, 14:05"
    case dayTime
    /// "March 2026"
    case month
  }

  private static let internetDate: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let internetDateWithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// Formats a stored ISO 8601 timestamp for display.
  ///
  /// Anything that does not parse comes back unchanged: a row showing a
  /// strange timestamp is a smaller failure than a row showing nothing.
  ///
  /// Each style is one `.dateTime` call, so the locale picks the field order
  /// and the separators. `locale` exists for the tests; call sites omit it.
  public static func date(_ iso: String, style: DateStyle, locale: Locale = .current) -> String {
    guard let parsed = parse(iso) else { return iso }
    switch style {
    case .day:
      return parsed.formatted(.dateTime.locale(locale).month(.abbreviated).day().year())
    case .dayTime:
      // `.minute()` is the shortest form: paired with an explicit hour width
      // it wrote 14:05 as "14:5". `.minute(.twoDigits)` asks for the two
      // digits rather than inheriting them from the locale's own pattern.
      // `.hour()` keeps the AM/PM marker, without which 15:05 and 03:05 look
      // the same on a twelve-hour clock.
      return parsed.formatted(
        .dateTime.locale(locale).month(.abbreviated).day().year().hour().minute(.twoDigits))
    case .month:
      return parsed.formatted(.dateTime.locale(locale).month(.wide).year())
    }
  }

  /// "2 days ago", from a stored ISO 8601 time; the string as stored when
  /// it does not parse.
  public static func relativeDate(_ iso: String, now: Date = Date(), locale: Locale = .current)
    -> String
  {
    guard let date = parse(iso) else { return iso }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
  }

  private static func parse(_ iso: String) -> Date? {
    internetDate.date(from: iso) ?? internetDateWithFraction.date(from: iso)
  }

  /// Splits a `yyyy-MM` bucket (what `availableMonths` returns) into the two
  /// pieces a month header draws at different weights.
  ///
  /// Anything that does not parse comes back as its own month with no year.
  public static func monthTitle(_ yyyyMM: String) -> (month: String, year: String) {
    let parts = yyyyMM.split(separator: "-")
    guard parts.count == 2,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let date = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: year, month: month, day: 1)
      )
    else {
      return (yyyyMM, "")
    }
    return (date.formatted(.dateTime.month(.wide)), String(year))
  }

  /// A human name for a MIME type ("PNG image"), falling back to the subtype
  /// in capitals when the system does not know the type.
  public static func kind(mime: String) -> String {
    if let type = UTType(mimeType: mime), let description = type.localizedDescription {
      return description
    }
    let subtype = mime.split(separator: "/").last.map(String.init) ?? mime
    return subtype.uppercased()
  }

  /// The short name a grid cell's format chip and the table's Kind column
  /// show ("JPEG"): the MIME subtype in capitals.
  public static func shortKind(mime: String) -> String {
    mime.split(separator: "/").last.map(String.init)?.uppercased() ?? "—"
  }

  /// "1920 × 1080", or nil when either side is missing or nonsensical.
  public static func dimensions(width: Int?, height: Int?) -> String? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    return "\(width) × \(height)"
  }

  /// "1.2 MB", the way Finder writes it; "0 bytes", not "Zero kB".
  public static func fileSize(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
  }

  /// An image this size or over is large — decimal,
  /// as `fileSize` writes it, so "1 MB" on screen is the line. The size
  /// marks use it now; a compression entry will later.
  public static let largeImageBytes: Int64 = 1_000_000

  public static func isLarge(_ bytes: Int64) -> Bool { bytes >= largeImageBytes }

  /// "1 asset" / "38 assets". `plural` defaults to `singular` + "s".
  public static func count(_ n: Int, singular: String, plural: String? = nil) -> String {
    let noun = n == 1 ? singular : (plural ?? singular + "s")
    return "\(n.formatted()) \(noun)"
  }
}
