import AppKit
import CatalogCore
import SwiftUI

// What List cards and Shelf cells share — the status drawn on the
// thumbnail itself, the one move-to-project menu behind three entries, and
// the hover-aware button styles.

/// What a card's phase reads as: the status layer's accessibility
/// label, the List's words, the Shelf's one word, and its tooltip.
struct DropZoneCardStatus: Equatable {
  enum Kind: Equatable {
    case waiting, compressing, uploading, review, uploaded, inLibrary, failed

    /// Not landed yet: the picture is dimmed inside a ring.
    var isPending: Bool { self == .waiting || self == .compressing || self == .uploading }
  }

  /// What a landed, recompressed upload adds after its time.
  struct Savings: Equatable {
    /// "−87%"; nil when the size barely changed.
    let percent: String?
    /// The percentage is a saving, and drawn as one.
    let isSaving: Bool
    /// "HEIC → JPEG"; nil when the format stayed.
    let formatChange: String?
  }

  let kind: Kind
  let accessibilityLabel: String
  let listText: String
  let shelfText: String
  let help: String?
  /// The Shelf word's tooltip: `help`, under the sizes of a recompressed
  /// upload.
  private(set) var shelfHelp: String?
  /// "Just now" alone, and what follows it; set together, or not at all.
  private(set) var when: String?
  private(set) var savings: Savings?
  /// A card held for review: what each choice sends.
  private(set) var review: Review?

  /// A reviewed card's words: the copy's sizes while its switch is on, the
  /// original's (and the copy's, set back) while it is off, or why there is
  /// no copy.
  struct Review: Equatable {
    /// The switch is on.
    let compresses: Bool
    let canCompress: Bool
    /// "4.6 MB → 336 kB", "640 kB", or "Original · not smaller".
    let lead: String
    /// "→ 188 kB": the copy that will not be sent, drawn stepped back.
    let unsent: String?
    let percent: String?
    let isSaving: Bool
    let formatChange: String?
    /// The Shelf's lead: "336 kB", "640 kB", or "Not smaller".
    let shelfLead: String
    /// The List's meta line: "6000 × 4000 → 2048 × 1365", "1920 × 480", or
    /// "2880 × 1800 · 412 kB".
    let meta: String
    /// Everything, for the Shelf's tooltip.
    let help: String

    init(prepared: PreparedDrop, useOriginal: Bool) {
      let sourceSize = prepared.sourceByteSize.map(PinaxFormat.fileSize)
      let sourceDimensions = PinaxFormat.dimensions(
        width: prepared.sourceWidth, height: prepared.sourceHeight)
      guard let copy = prepared.compression else {
        compresses = false
        canCompress = false
        let reason = prepared.originalReason ?? .notSmaller
        lead = Self.note(reason)
        shelfLead = Self.shortNote(reason)
        unsent = nil
        percent = nil
        isSaving = false
        formatChange = nil
        meta = [sourceDimensions, sourceSize].compactMap(\.self).joined(separator: " · ")
        help = meta
        return
      }
      compresses = !useOriginal
      canCompress = true
      percent = compresses ? copy.percentChange : nil
      isSaving = copy.isSmaller
      formatChange = compresses ? copy.formatChange : nil
      let copySize = PinaxFormat.fileSize(copy.byteSize)
      let original = sourceSize ?? PinaxFormat.fileSize(copy.sourceByteSize)
      let copyDimensions = PinaxFormat.dimensions(width: copy.width, height: copy.height)
      if compresses {
        lead = copy.sizeChange
        unsent = nil
        shelfLead = copySize
        meta =
          sourceDimensions != nil && copyDimensions != nil && sourceDimensions != copyDimensions
          ? "\(sourceDimensions!) → \(copyDimensions!)" : (copyDimensions ?? sourceDimensions ?? "")
      } else {
        lead = original
        unsent = "→ \(copySize)"
        shelfLead = original
        meta = sourceDimensions ?? ""
      }
      help = [copy.sizeChange, copyDimensions, copy.formatChange].compactMap(\.self)
        .joined(separator: " · ")
    }

    static func note(_ reason: PreparedDrop.OriginalReason) -> String {
      switch reason {
      case .notSmaller: "Original · not smaller"
      case .notCompressible: "Original · not compressible"
      case .inLibrary: "Already in library"
      }
    }

    static func shortNote(_ reason: PreparedDrop.OriginalReason) -> String {
      switch reason {
      case .notSmaller: "Not smaller"
      case .notCompressible: "Original"
      case .inLibrary: "In library"
      }
    }

    var listText: String {
      [[lead, unsent].compactMap(\.self).joined(separator: " "), percent, formatChange]
        .compactMap(\.self).joined(separator: " · ")
    }

    var shelfText: String {
      [[shelfLead, unsent].compactMap(\.self).joined(separator: " "), percent]
        .compactMap(\.self).joined(separator: " · ")
    }
  }

  init(card: DropZoneModel.UploadCard, now: Date = Date()) {
    switch card.phase {
    case .waiting:
      self.init(.waiting, "Waiting", "Waiting…", "Waiting", nil)
    case .compressing:
      self.init(.compressing, "Compressing", "Compressing…", "Compressing", nil)
    case .uploading:
      self.init(.uploading, "Uploading", "Uploading…", "Uploading", nil)
    case .review(let useOriginal):
      let review = Review(
        prepared: card.prepared ?? PreparedDrop(fileURL: card.fileURL, projectSlug: card.projectSlug),
        useOriginal: useOriginal)
      self.init(.review, "Ready to upload", review.listText, review.shelfText, nil)
      self.review = review
      shelfHelp = review.help
    case .done(let outcome) where outcome.deduplicated:
      self.init(
        .inLibrary, "Already in library", "Already in library", "In library",
        "Same image is already in Pinax; no bytes were uploaded.")
    case .done(let outcome):
      let when = Self.uploadedWhen(card: card, outcome: outcome, now: now)
      guard let compression = card.compression else {
        self.init(.uploaded, "Uploaded", when, when, outcome.url)
        break
      }
      let savings = Savings(
        percent: compression.percentChange, isSaving: compression.isSmaller,
        formatChange: compression.formatChange)
      let short = [when, savings.percent].compactMap(\.self).joined(separator: " · ")
      let full = [short, savings.formatChange].compactMap(\.self).joined(separator: " · ")
      self.init(.uploaded, "Uploaded", full, short, outcome.url)
      self.when = when
      self.savings = savings
    case .failed(let message):
      self.init(.failed, "Failed", "Couldn’t upload", "Failed", message)
    }
    if case .done(let outcome) = card.phase, let compression = card.compression {
      let sizes = [
        PinaxFormat.dimensions(width: outcome.width, height: outcome.height),
        compression.sizeChange, compression.formatChange,
      ].compactMap(\.self).joined(separator: " · ")
      shelfHelp = [sizes, help].compactMap(\.self).joined(separator: "\n")
    }
  }

  private init(_ kind: Kind, _ label: String, _ list: String, _ shelf: String, _ help: String?) {
    self.kind = kind
    accessibilityLabel = label
    listText = list
    shelfText = shelf
    self.help = help
    shelfHelp = help
  }

  /// "Just now" for the first minute of a landing this run; otherwise how
  /// long ago the catalog says it was uploaded.
  static func uploadedWhen(
    card: DropZoneModel.UploadCard, outcome: UploadOutcome, now: Date
  ) -> String {
    if let landedAt = card.landedAt, now.timeIntervalSince(landedAt) < 60 { return "Just now" }
    return PinaxFormat.relativeDate(outcome.uploadedAt, now: now)
  }
}

/// How the status layer moves: the arc turns and the
/// fresh-upload glow fades — unless Reduce Motion is on, when the arc is a
/// still quarter and the glow simply goes.
struct DropZoneMotion: Equatable {
  /// The dotted ring's dots travel round while compressing.
  var ringMarches = false
  /// The upload ring fills from 12 o'clock while uploading.
  var ringFills = false
  /// A fresh upload's full ring fades out.
  var ringFades = false
}

/// Each card's status motion as its view drew it, in card order of
/// reporting — read by a hosted test, never by the panel.
struct DropZoneMotionKey: PreferenceKey {
  static var defaultValue: [UUID: DropZoneMotion] = [:]
  static func reduce(value: inout [UUID: DropZoneMotion], nextValue: () -> [UUID: DropZoneMotion]) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// The one menu behind all three move entries (the card's
/// `folder.badge.plus`, its project token, and its context menu's
/// Projects ▸): No project, then every project, the card's own checked.
/// Choosing one moves the asset through `DropZoneModel.changeProject`.
enum DropZoneProjectMenu {
  struct Item: Equatable, Identifiable {
    let slug: String?
    let title: String
    let isChecked: Bool
    var id: String { slug ?? "" }
  }

  static let help = "Move to Project…"

  static func items(projects: [Project], current: String?) -> [Item] {
    [Item(slug: nil, title: "No project", isChecked: current == nil)]
      + projects.map { Item(slug: $0.slug, title: $0.name, isChecked: $0.slug == current) }
  }
}

/// The menu's rows, as checkable toggles. Choosing the checked row again is
/// a no-op in the model.
struct DropZoneProjectMenuItems: View {
  let card: DropZoneModel.UploadCard
  @ObservedObject var model: DropZoneModel

  var body: some View {
    ForEach(DropZoneProjectMenu.items(projects: model.projects, current: card.projectSlug)) { item in
      Toggle(
        item.title,
        isOn: Binding(
          get: { item.isChecked },
          set: { _ in model.changeProject(card.id, to: item.slug) }))
    }
  }
}

/// A card's project name, "No project" when it has none.
func dropZoneProjectName(_ slug: String?, in projects: [Project]) -> String {
  if let slug, let project = projects.first(where: { $0.slug == slug }) { return project.name }
  return "No project"
}

extension DropZoneCardStatus {
  /// `listText` as drawn: a saving's percentage in its own hue, semibold;
  /// a copy that will not be sent in `unsent`.
  func listWords(saving: Color, unsent: Color = .secondary) -> Text {
    if let review {
      return Self.reviewWords(
        review, lead: review.lead, saving: saving, unsent: unsent, format: true)
    }
    guard let when, let savings else { return Text(listText) }
    var words = Text(when)
    if let percent = savings.percent {
      words = Text("\(words) · \(Self.percentWord(percent, savings.isSaving, saving))")
    }
    if let formatChange = savings.formatChange {
      words = Text("\(words) · \(formatChange)")
    }
    return words
  }

  /// The Shelf's word as drawn: `shelfText`, or with `short` only the
  /// percentage, for a cell too narrow for both.
  func shelfWords(saving: Color, unsent: Color = .secondary, short: Bool = false) -> Text {
    if let review {
      return Self.reviewWords(
        review, lead: review.shelfLead, saving: saving, unsent: unsent, format: false)
    }
    guard let when, let savings, let percent = savings.percent else { return Text(shelfText) }
    let word = Self.percentWord(percent, savings.isSaving, saving)
    return short ? word : Text("\(when) · \(word)")
  }

  private static func reviewWords(
    _ review: Review, lead: String, saving: Color, unsent: Color, format: Bool
  ) -> Text {
    var words = Text(lead)
    if let copy = review.unsent {
      words = Text("\(words) \(Text(copy).foregroundStyle(unsent))")
    }
    if let percent = review.percent {
      words = Text("\(words) · \(percentWord(percent, review.isSaving, saving))")
    }
    if format, let formatChange = review.formatChange {
      words = Text("\(words) · \(formatChange)")
    }
    return words
  }

  private static func percentWord(_ percent: String, _ isSaving: Bool, _ hue: Color) -> Text {
    isSaving ? Text(percent).foregroundStyle(hue).fontWeight(.semibold) : Text(percent)
  }
}

// MARK: - The status layer

/// The thumbnail with its status drawn on it: pending images are
/// dimmed inside a ring (travelling dots around a glass knob while
/// compressing, a filling arc while uploading); a fresh upload
/// glows briefly; a deduplicated one has a see-through copy behind it; a
/// failed one is grey with a glass retry knob.
struct StatusThumbnail: View {
  let card: DropZoneModel.UploadCard
  /// nil = as wide as offered (Shelf).
  let width: CGFloat?
  let height: CGFloat
  let radius: CGFloat
  let knob: CGFloat
  let reducesMotion: Bool
  let retry: DropZoneCardAction
  @Environment(\.colorScheme) private var colorScheme
  /// When this view saw the upload begin; the ring's fill counts from here.
  @State private var uploadStart: Date?
  /// Set once a fresh upload's ring has closed and faded, so its timeline
  /// stops.
  @State private var ringFinished = false

  private var palette: DropZonePalette { .of(colorScheme) }
  private var status: DropZoneCardStatus { DropZoneCardStatus(card: card) }
  private typealias M = DesignMetrics.dropZone

  var body: some View {
    image
      .frame(width: width, height: height)
      .frame(maxWidth: width == nil ? .infinity : nil)
      .clipShape(shape(radius))
      .opacity(status.kind.isPending ? M.pendingImageOpacity : 1)
      .saturation(status.kind == .failed ? 0 : 1)
      .brightness(status.kind == .failed ? M.failedImageBrightness : 0)
      .background { dedupeCopy }
      .overlay { paperRing }
      .overlay { ring }
      .overlay { compressingRing }
      .overlay { compressingKnob }
      .overlay { retryKnob }
      .overlay {
        // The layer's own extent: the farthest any status drawing reaches.
        // Measured on the enlarged clear box itself: a frame read after the
        // negative padding is the image's again.
        Color.clear
          .dropZoneLayout(.statusLayer, card: card.id)
          .padding(-layerOutset)
          .allowsHitTesting(false)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(status.accessibilityLabel)
      .preference(key: DropZoneMotionKey.self, value: [card.id: motion])
      .onChange(of: status.kind, initial: true) { _, kind in
        if kind == .uploading, uploadStart == nil { uploadStart = Date() }
      }
      .task(id: card.landedAt) {
        guard let landedAt = card.landedAt else { return }
        let left = UploadRing.finishTime - Date().timeIntervalSince(landedAt)
        if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
        if !Task.isCancelled { ringFinished = true }
      }
  }

  private var motion: DropZoneMotion {
    DropZoneMotion(
      ringMarches: status.kind == .compressing && !reducesMotion,
      ringFills: status.kind == .uploading && !reducesMotion,
      ringFades: status.kind == .uploaded && card.landedAt != nil && !ringFinished
        && !reducesMotion)
  }

  private var layerOutset: CGFloat {
    switch status.kind {
    case .waiting, .compressing, .uploading: M.ringReach
    case .inLibrary: M.statusOutset
    case .uploaded: ringFinished || card.landedAt == nil ? 0 : M.ringReach
    case .review, .failed: 0
    }
  }

  private func shape(_ radius: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
  }

  /// The picture in a box that takes the size it is offered: a filled
  /// image never widens the box (it is clipped to it), and an item without
  /// a picture shows the photo symbol on the paper ground.
  private var image: some View {
    Color.clear
      .overlay {
        if let thumbnail = card.thumbnail {
          Image(decorative: thumbnail, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          Image(systemName: "photo")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.paper)
        }
      }
      .clipped()
  }

  @ViewBuilder
  private var dedupeCopy: some View {
    if status.kind == .inLibrary {
      image
        .clipShape(shape(radius))
        .opacity(M.dedupeCopyOpacity)
        .padding(
          EdgeInsets(
            top: -M.dedupeOffset, leading: M.dedupeOffset, bottom: M.dedupeOffset,
            trailing: -M.dedupeOffset))
    }
  }

  @ViewBuilder
  private var paperRing: some View {
    if status.kind == .inLibrary {
      shape(radius).strokeBorder(palette.paper, lineWidth: M.paperRingWidth)
    }
  }

  /// The upload ring: a thin
  /// ring just outside the image, its track faint while waiting; while
  /// uploading it fills clockwise from 12 o'clock; once landed it closes
  /// and fades out. The upload pipeline reports no byte progress: the fill
  /// is the time
  /// since the upload began (`UploadRing.fill`), never reaching full until
  /// the upload lands.
  @ViewBuilder
  private var ring: some View {
    let fresh = status.kind == .uploaded && card.landedAt != nil && !ringFinished
    if status.kind == .waiting || status.kind == .uploading || fresh {
      let shape = UploadRingShape(radius: radius + M.ringOutset)
      Group {
        if status.kind == .waiting {
          shape.stroke(palette.track, lineWidth: M.ringWidth)
        } else if reducesMotion {
          // Still: the whole ring while uploading; gone once landed.
          if status.kind == .uploading {
            shape.stroke(palette.uploading, lineWidth: M.ringWidth)
          }
        } else {
          TimelineView(.animation) { context in
            let ring = UploadRing.at(
              context.date, startedAt: uploadStart, landedAt: fresh ? card.landedAt : nil)
            ZStack {
              shape.stroke(palette.track, lineWidth: M.ringWidth)
              shape.trim(from: 0, to: ring.fill)
                .stroke(
                  palette.uploading, style: StrokeStyle(lineWidth: M.ringWidth, lineCap: .round))
            }
            .opacity(ring.opacity)
          }
        }
      }
      .padding(-M.ringOutset)
      .allowsHitTesting(false)
    }
  }

  /// Compression reports no progress, so the dots only travel round; with
  /// Reduce Motion they stand still.
  @ViewBuilder
  private var compressingRing: some View {
    if status.kind == .compressing {
      let shape = UploadRingShape(radius: radius + M.ringOutset)
      let pitch = knob > M.knobList ? M.ringDotPitchLarge : M.ringDotPitch
      GeometryReader { proxy in
        // A whole number of dots, so none bunch up where the path closes.
        let spacing = shape.dotSpacing(in: proxy.size, near: pitch)
        TimelineView(.animation(paused: reducesMotion)) { context in
          shape.stroke(
            palette.uploading,
            style: StrokeStyle(
              lineWidth: M.ringWidth, lineCap: .round, dash: [0, spacing],
              dashPhase: reducesMotion
                ? 0 : CompressingRing.phase(at: context.date, spacing: spacing)))
        }
      }
      .padding(-M.ringOutset)
      .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var compressingKnob: some View {
    if status.kind == .compressing {
      glassKnob(CompressingRing.symbol)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  /// A white symbol on a small round of dark glass over the picture.
  private func glassKnob(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .fontWeight(.semibold)
      .imageScale(knob > M.knobList ? .large : .small)
      .foregroundStyle(.white)
      .frame(width: knob, height: knob)
      .background(.ultraThinMaterial, in: Circle())
      .background(Color.black.opacity(M.knobScrim), in: Circle())
      .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private var retryKnob: some View {
    if status.kind == .failed {
      Button(action: retry.perform) {
        glassKnob(retry.symbol)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help(retry.help)
      .accessibilityLabel(retry.help)
      .dropZoneLayout(.retry, card: card.id)
    }
  }
}

/// The compressing state's symbol and the travel of its dots.
enum CompressingRing {
  static let symbol = "arrow.down.right.and.arrow.up.left"
  /// Points a second along the path.
  static let speed: Double = 10

  /// Clockwise, like the upload ring's fill; one dot spacing per cycle.
  static func phase(at date: Date, spacing: CGFloat) -> CGFloat {
    guard spacing > 0 else { return 0 }
    let travelled = date.timeIntervalSinceReferenceDate * speed
    return -CGFloat(travelled.truncatingRemainder(dividingBy: Double(spacing)))
  }
}

/// The upload ring's fill and opacity at a moment: while uploading the
/// fill eases towards (never reaching) `UploadRing.ceiling`; once landed
/// it closes to full over `closeTime`, then fades over `fadeTime`. A card
/// first seen after it landed starts closed.
enum UploadRing {
  static let ceiling: Double = 0.92
  /// Seconds for the fill to cover about 63 % of the way to the ceiling.
  static let pace: Double = 2.5
  static let closeTime: Double = 0.25
  static let fadeTime: Double = 0.8
  static var finishTime: Double { closeTime + fadeTime }

  static func fill(after seconds: Double) -> Double {
    ceiling * (1 - exp(-max(seconds, 0) / pace))
  }

  static func at(_ now: Date, startedAt: Date?, landedAt: Date?) -> (fill: Double, opacity: Double) {
    guard let landedAt else {
      return (fill(after: startedAt.map { now.timeIntervalSince($0) } ?? 0), 1)
    }
    let reached = startedAt.map { fill(after: landedAt.timeIntervalSince($0)) } ?? 1
    let since = now.timeIntervalSince(landedAt)
    let closing = min(max(since / closeTime, 0), 1)
    let fading = min(max((since - closeTime) / fadeTime, 0), 1)
    return (reached + (1 - reached) * closing, 1 - fading)
  }
}

/// A rounded rectangle traced clockwise from the middle of its top edge,
/// so a trim from 0 starts at 12 o'clock.
struct UploadRingShape: Shape {
  let radius: CGFloat

  func path(in rect: CGRect) -> Path {
    let r = min(radius, rect.width / 2, rect.height / 2)
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
      tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.minY),
      tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
    path.closeSubpath()
    return path
  }

  /// The spacing closest to `pitch` that divides the outline into a whole
  /// number of parts.
  func dotSpacing(in size: CGSize, near pitch: CGFloat) -> CGFloat {
    let r = min(radius, size.width / 2, size.height / 2)
    let length = 2 * (size.width - 2 * r) + 2 * (size.height - 2 * r) + 2 * .pi * r
    guard length > 0, pitch > 0 else { return pitch }
    return length / max((length / pitch).rounded(), 1)
  }
}

/// The card buttons' icons and words, shared with the menu bar panel's
/// RECENT grid so the two never drift apart.
enum DropZoneCardActionStyle {
  static let linkSymbol = "link"
  static let markdownSymbol = "chevron.left.forwardslash.chevron.right"
  static let quickLookSymbol = "eye"
  static let linkHelp = "Copy URL"
  static let markdownHelp = "Copy Markdown"
  static let quickLookHelp = "Quick Look"
}

/// One icon button of a card: what it shows, says and does.
struct DropZoneCardAction: Identifiable {
  let id: String
  let symbol: String
  let help: String
  let perform: @MainActor () -> Void
}

// MARK: - Controls

/// An icon button with a rounded hover ground and the canvas's weight.
/// The control is a plain `Button`; no system style draws a hover ground on
/// macOS 15, so this style only adds that ground and the size.
struct DropZoneIconButtonStyle: ButtonStyle {
  var width: CGFloat = DesignMetrics.dropZone.iconButtonWidth
  var height: CGFloat = DesignMetrics.dropZone.iconButtonHeight
  /// Over an image (the Shelf bar): white symbols on a dark scrim.
  var onImage = false

  func makeBody(configuration: Configuration) -> some View {
    HoverGround(
      configuration: configuration, width: width, height: height, onImage: onImage)
  }

  private struct HoverGround: View {
    let configuration: Configuration
    let width: CGFloat
    let height: CGFloat
    let onImage: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
      let palette = DropZonePalette.of(onImage ? .dark : colorScheme)
      let active = hovered && isEnabled
      configuration.label
        .fontWeight(.medium)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(onImage ? Color.white : (hovered ? palette.primary : palette.secondary))
        .scaleEffect(
          DropZoneIconMotion.scale(
            hovered: active, pressed: configuration.isPressed && isEnabled,
            reducesMotion: reducesMotion))
        .frame(width: width, height: height)
        .background(
          active ? palette.buttonHover : Color.clear,
          in: RoundedRectangle(cornerRadius: DesignMetrics.dropZone.iconButtonRadius))
        .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: DropZoneIconMotion.fade), value: active)
        .animation(.easeOut(duration: DropZoneIconMotion.fade), value: configuration.isPressed)
        .onHover { hovered = $0 }
    }
  }
}

/// An icon button's motion: the hover ground fades in
/// and out over about 120 ms; the symbol grows a little under the pointer
/// and shrinks a little while pressed — no bounce, no colour change. With
/// Reduce Motion only the ground fades; the symbol keeps its size.
enum DropZoneIconMotion {
  static let fade: Double = 0.12
  static let hoverScale: CGFloat = 1.06
  static let pressScale: CGFloat = 0.94

  static func scale(hovered: Bool, pressed: Bool, reducesMotion: Bool) -> CGFloat {
    if reducesMotion { return 1 }
    if pressed { return pressScale }
    return hovered ? hoverScale : 1
  }
}

/// The header's framed project pill: a filled, outlined pill whose
/// outline turns accent under the pointer. The control is a `Menu` shown as
/// a button; this style draws only the frame.
struct DropZonePillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Pill(configuration: configuration)
  }

  private struct Pill: View {
    let configuration: Configuration
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      let palette = DropZonePalette.of(colorScheme)
      let shape = RoundedRectangle(
        cornerRadius: DesignMetrics.dropZone.pillRadius, style: .continuous)
      configuration.label
        .padding(.horizontal, DesignMetrics.dropZone.pillPadding)
        .frame(height: DesignMetrics.dropZone.pillHeight)
        .background(palette.pillFill, in: shape)
        .overlay(
          shape.strokeBorder(
            hovered ? palette.accent : palette.pillStroke, lineWidth: DesignMetrics.dropZone.rimWidth))
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(shape)
        .onHover { hovered = $0 }
    }
  }
}

/// The project token on a card: folder, name, chevron — itself the
/// move menu's button, a light ground under the pointer.
struct DropZoneTokenButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Token(configuration: configuration)
  }

  private struct Token: View {
    let configuration: Configuration
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      let palette = DropZonePalette.of(colorScheme)
      configuration.label
        .padding(.vertical, DesignMetrics.dropZone.tokenPaddingV)
        .padding(.horizontal, DesignMetrics.dropZone.tokenPaddingH)
        .background(
          hovered && isEnabled ? palette.buttonHover : palette.tokenFill,
          in: RoundedRectangle(cornerRadius: DesignMetrics.dropZone.tokenRadius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
  }
}

/// The token, as the move menu.
struct DropZoneProjectToken: View {
  let card: DropZoneModel.UploadCard
  @ObservedObject var model: DropZoneModel
  let canMove: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = DropZonePalette.of(colorScheme)
    let name = dropZoneProjectName(card.projectSlug, in: model.projects)
    Menu {
      DropZoneProjectMenuItems(card: card, model: model)
    } label: {
      HStack(spacing: DesignMetrics.dropZone.tokenGap) {
        Image(systemName: "folder")
          .imageScale(.small)
        Text(name)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.down")
          .imageScale(.small)
      }
      .foregroundStyle(palette.secondary)
      .pinaxSecondary()
      .fontWeight(.medium)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(DropZoneTokenButtonStyle())
    .fixedSize()
    .disabled(!canMove)
    .help(DropZoneProjectMenu.help)
    .accessibilityLabel("\(DropZoneProjectMenu.help) \(name)")
  }
}

/// The card's context menu — copy, look, then Projects ▸, and Retry on
/// a failed card. Shared by List and Shelf.
struct DropZoneCardContextMenu: View {
  let card: DropZoneModel.UploadCard
  @ObservedObject var model: DropZoneModel
  let actions: [DropZoneCardAction]
  let retry: DropZoneCardAction
  let canMove: Bool

  var body: some View {
    ForEach(actions) { action in
      Button(action.help, action: action.perform)
        .disabled(!canMove)
    }
    Divider()
    Menu("Projects") {
      DropZoneProjectMenuItems(card: card, model: model)
    }
    .disabled(!canMove)
    if case .failed = card.phase {
      Button(retry.help, action: retry.perform)
    }
  }
}

// MARK: - List card

/// One dropped item as a List row: the 54 pt status thumbnail; the name; the
/// status words; size · bytes and the project token; the action row, always all
/// out. Every phase is the same height, so a card that finishes uploading does
/// not move the list — a failure's message takes the meta line's place.
struct ResultCardView: View {
  let card: DropZoneModel.UploadCard
  @ObservedObject var model: DropZoneModel
  @ObservedObject var state: DropZoneViewState
  @Environment(\.colorScheme) private var colorScheme
  @State private var hovered = false

  typealias Action = DropZoneCardAction
  private var palette: DropZonePalette { .of(colorScheme) }
  private typealias M = DesignMetrics.dropZone

  var body: some View {
    HStack(alignment: .top, spacing: M.cardGap) {
      StatusThumbnail(
        card: card, width: M.thumbnail, height: M.thumbnail, radius: M.thumbnailRadius,
        knob: M.knobList, reducesMotion: state.reducesMotion, retry: retryAction
      )
      .onContinuousHover(coordinateSpace: .named(DropZoneView.space)) { phase in
        state.thumbnailHover(
          phase, cardID: card.id,
          imageSize: card.thumbnail.map { CGSize(width: $0.width, height: $0.height) })
      }
      .dropZoneLayout(.thumbnail, card: card.id)
      VStack(alignment: .leading, spacing: M.textSpacing) {
        Text(card.filename)
          .fontWeight(.semibold)
          .pinaxBody()
          .lineLimit(1)
          .truncationMode(.middle)
          .help(card.fileURL.path)
          .dropZoneLayout(.filename, card: card.id)
        statusLine
          .dropZoneLayout(.statusText, card: card.id)
        metaRow
        actionRow
          .padding(.leading, -M.actionRowLead)
          .dropZoneLayout(.buttons, card: card.id)
      }
      .dropZoneLayout(.text, card: card.id)
      Spacer(minLength: 0)
    }
    .padding(M.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The drop zone panel's container kind; lifted under the pointer.
    .background {
      let shape = RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous)
      shape
        .fill(hovered ? palette.cardHoverFill : palette.cardFill)
        .overlay(
          shape.strokeBorder(
            hovered ? palette.cardHoverRim : palette.cardRim, lineWidth: M.cardRimWidth))
        .shadow(
          color: hovered ? palette.cardHoverShadow : palette.cardShadow,
          radius: hovered ? M.cardHoverShadowRadius : M.cardShadowRadius,
          y: hovered ? M.cardHoverShadowOffset : M.cardShadowOffset)
    }
    .onHover { hovered = $0 }
    .contextMenu {
      DropZoneCardContextMenu(
        card: card, model: model, actions: actions, retry: retryAction, canMove: isDone)
    }
    .dropZoneLayout(.card, card: card.id)
  }

  private var status: DropZoneCardStatus { DropZoneCardStatus(card: card) }

  /// The phase in words; a refused move says why instead. "Just now"
  /// becomes a relative time after the first minute.
  @ViewBuilder
  private var statusLine: some View {
    if let moveError = card.moveError {
      Text(moveError)
        .foregroundStyle(palette.failed)
        .pinaxSecondary()
        .lineLimit(1)
        .help(moveError)
        .dropZoneLayout(.moveError, card: card.id)
    } else if case .failed = card.phase {
      HStack(spacing: 0) {
        Text("\(status.listText) · ")
          .foregroundStyle(palette.failed)
          .pinaxSecondary()
        Button(action: retryAction.perform) {
          Text("Retry").underline()
            .foregroundStyle(palette.failed)
            .pinaxSecondary()
        }
        .buttonStyle(.plain)
        .help(retryAction.help)
      }
      .lineLimit(1)
    } else if status.kind == .review {
      status.listWords(saving: palette.done, unsent: palette.tertiary)
        .foregroundStyle(palette.secondary)
        .pinaxSecondary()
        .monospacedDigit()
        .lineLimit(1)
        .help(status.listText)
    } else if status.kind == .uploaded {
      TimelineView(.periodic(from: .now, by: 30)) { context in
        DropZoneCardStatus(card: card, now: context.date).listWords(saving: palette.done)
          .foregroundStyle(palette.secondary)
          .pinaxSecondary()
          .lineLimit(1)
          .help(status.help ?? "")
      }
    } else {
      Text(status.listText)
        .foregroundStyle(palette.secondary)
        .pinaxSecondary()
        .lineLimit(1)
        .help(status.help ?? "")
    }
  }

  /// Size · bytes, or before → after; a failure's message in place of the size (the error
  /// line), its full text in the tooltip.
  private var metaRow: some View {
    HStack(spacing: M.metaSpacing) {
      if case .failed(let message) = card.phase {
        Text(message)
          .foregroundStyle(palette.failed)
          .pinaxSecondary()
          .lineLimit(1)
          .truncationMode(.tail)
          .help(message)
          .dropZoneLayout(.error, card: card.id)
      } else {
        // With nothing to say yet the line is blank but keeps its height, so
        // every phase is one card height.
        Text(metaText.isEmpty ? " " : metaText)
          .foregroundStyle(palette.secondary)
          .pinaxSecondary()
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .help(card.compression?.settingsSummary ?? "")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .dropZoneLayout(.meta, card: card.id)
  }

  /// Pixel size · bytes once the upload has landed, the bytes as before →
  /// after for a recompressed copy; while that copy uploads, before → after
  /// alone; otherwise nothing.
  var metaText: String {
    if card.phase.isReview { return status.review?.meta ?? "" }
    if card.phase == .uploading { return card.compression?.sizeChange ?? "" }
    guard case .done(let outcome) = card.phase else { return "" }
    var parts: [String] = []
    if let dimensions = PinaxFormat.dimensions(width: outcome.width, height: outcome.height) {
      parts.append(dimensions)
    }
    parts.append(card.compression?.sizeChange ?? PinaxFormat.fileSize(outcome.byteSize))
    return parts.joined(separator: " · ")
  }

  /// The meta line in words, project included (the project shows as the
  /// token on screen).
  var metaLine: String {
    ([metaText].filter { !$0.isEmpty } + [dropZoneProjectName(card.projectSlug, in: model.projects)])
      .joined(separator: " · ")
  }

  var isDone: Bool {
    if case .done = card.phase { return true }
    return false
  }

  /// The icon buttons, Copy URL (the primary one) first.
  var actions: [Action] { Self.actions(card.id, model) }

  static func actions(_ id: UUID, _ model: DropZoneModel) -> [Action] {
    [
      Action(
        id: "copyURL", symbol: DropZoneCardActionStyle.linkSymbol,
        help: DropZoneCardActionStyle.linkHelp
      ) { [model] in model.copyURL(id) },
      Action(
        id: "copyMarkdown", symbol: DropZoneCardActionStyle.markdownSymbol,
        help: DropZoneCardActionStyle.markdownHelp
      ) { [model] in model.copyMarkdown(id) },
      Action(
        id: "quickLook", symbol: DropZoneCardActionStyle.quickLookSymbol,
        help: DropZoneCardActionStyle.quickLookHelp
      ) { [model] in model.quickLook(id) },
    ]
  }

  /// The failed card's retry (the knob, the status line's Retry and the
  /// context menu's), as one testable action.
  var retryAction: Action { Self.retryAction(card.id, model) }

  static func retryAction(_ id: UUID, _ model: DropZoneModel) -> Action {
    Action(id: "retry", symbol: "arrow.clockwise", help: "Retry") { [model] in model.retry(id) }
  }

  /// The icon row: the actions, enabled once the upload has landed (present
  /// in every phase, so the row never appears or disappears under the
  /// pointer), and the project token at its end — the one move control on
  /// the card besides the context menu.
  /// In review the switch takes the buttons' place: there is no link yet.
  private var actionRow: some View {
    HStack(spacing: M.iconButtonGap) {
      if model.reviewBatch.contains(card.id) {
        DropZoneReviewSwitch(card: card, model: model)
          .padding(.leading, M.actionRowLead)
          .frame(height: M.iconButtonHeight)
      } else {
        ForEach(actions) { action in
          actionButton(action)
            .disabled(!isDone)
            .dropZoneLayout(.action(action.id), card: card.id)
        }
      }
      Spacer(minLength: M.iconButtonGap)
      DropZoneProjectToken(card: card, model: model, canMove: isDone)
        .dropZoneLayout(.projectToken, card: card.id)
    }
  }

  func actionButton(_ action: Action) -> some View {
    Button(action: action.perform) {
      Image(systemName: action.symbol)
    }
    .buttonStyle(DropZoneIconButtonStyle())
    .help(action.help)
    .accessibilityLabel(action.help)
    .fixedSize()
  }
}
