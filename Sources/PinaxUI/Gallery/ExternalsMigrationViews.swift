import CatalogCore
import SwiftUI

/// Migrate N Links to Your
/// Bucket?, in Delete Permanently…'s layout — title, sentence, the grouped
/// summary, the hosts, the unclean sources, the tip, then Show Changes… /
/// Cancel / Migrate. Every string comes from `ExternalMigrationConfirmation`.
struct ExternalMigrationSheet: View {
  @ObservedObject var model: ExternalsModel
  let confirmation: ExternalMigrationConfirmation

  static let width: CGFloat = 600
  /// Board Confirm: the host list scrolls past about 190 pt.
  static let hostsMaxHeight: CGFloat = 190
  /// The summary's rows, and the hosts' and images' (one height for both
  /// lists so their columns read as one table).
  static let summaryRowHeight: CGFloat = 36
  static let rowHeight: CGFloat = 30
  /// Every card's rows start and end this far in, so icons, badges and the
  /// size column line up from card to card.
  static let rowInset: CGFloat = DesignMetrics.spacing.m

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text(confirmation.title)
        .pinaxTitle()
        .lineLimit(1)
      Text(ExternalMigrationConfirmation.subtitle)
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
      summary
      if !confirmation.hosts.isEmpty {
        hosts
      }
      if !confirmation.images.isEmpty {
        ExternalMigrationImageList(confirmation: confirmation)
      }
      ForEach(confirmation.sources) { source in
        sourceRow(source)
      }
      if let refusal = model.migrationRefusal {
        HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(PinaxPalette.red)
          Text(refusal.message)
            .pinaxSecondary()
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(ExternalMigrationConfirmation.tip)
        .pinaxCaption()
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Show Changes…") { Task { await model.showMigrationChanges() } }
          .disabled(confirmation.links == 0)
        Spacer()
        Button("Cancel") { model.dismissMigrationSheet() }
          .keyboardShortcut(.cancelAction)
        if model.migrationRefusal?.needsPreparing == true {
          Button("Prepare Again") { Task { await model.prepareMigrationAgain() } }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(PinaxPalette.accentFill)
        } else {
          Button(confirmation.migrateTitle) { Task { await model.confirmMigration() } }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(PinaxPalette.accentFill)
            .disabled(!model.isMigrateEnabled)
        }
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: Self.width)
    .onExitCommand { model.dismissMigrationSheet() }
    // Show Changes…: a sheet on the sheet.
    .sheet(
      isPresented: Binding(
        get: { model.migrationDiff != nil },
        set: { if !$0 { model.closeMigrationChanges() } })
    ) {
      ChangesDiffSheet(text: model.migrationDiff ?? "") { model.closeMigrationChanges() }
    }
  }

  /// Icon, semibold label, the value in one line; the old
  /// line under it is the tooltip. Same card, edges and insets as the
  /// hosts and images below it.
  private var summary: some View {
    VStack(spacing: 0) {
      ForEach(confirmation.lines, id: \.label) { line in
        if line.label != confirmation.lines.first?.label { Self.rowDivider }
        HStack(spacing: DesignMetrics.spacing.s) {
          ColorSquare(
            size: .sidebar, color: ExternalMigrationLineValue.color(line.tone),
            content: .symbol(ExternalMigrationLineValue.symbol(line.tone)))
          Text(line.label)
            .fontWeight(.semibold)
            .lineLimit(1)
            .fixedSize()
          Spacer(minLength: DesignMetrics.spacing.m)
          ExternalMigrationLineValue(line: line)
        }
        .padding(.horizontal, Self.rowInset)
        .frame(height: Self.summaryRowHeight)
        .help(line.detail ?? "")
      }
    }
    .migrationCard()
  }

  private var hosts: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      Self.sectionTitle(confirmation.hostsTitle)
      ScrollView {
        VStack(spacing: 0) {
          ForEach(confirmation.hosts) { host in
            if host.id != confirmation.hosts.first?.id { Self.rowDivider }
            HStack(spacing: DesignMetrics.spacing.s) {
              ExternalDomainSquare(host: host.host)
              // The link count rides after the name, in brackets.
              HStack(spacing: 4) {
                Text(host.host)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Text("(\(host.links.formatted()))")
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
                  .fixedSize()
              }
              Spacer(minLength: DesignMetrics.spacing.s)
              if let tip = host.tip {
                Text(tip)
                  .pinaxCaption()
                  .foregroundStyle(host.isWarning ? AnyShapeStyle(PinaxPalette.orange) : AnyShapeStyle(.secondary))
                  .lineLimit(1)
              }
              // The host's bytes to upload; a broken host's is empty.
              ExternalSizeText(bytes: host.bytes, isLarge: host.hasLarge)
                .frame(width: DesignMetrics.externalsTable.sizeWidth, alignment: .trailing)
            }
            .padding(.horizontal, Self.rowInset)
            .frame(height: Self.rowHeight)
          }
        }
      }
      .frame(maxHeight: Self.hostsMaxHeight)
      .fixedSize(horizontal: false, vertical: true)
      .migrationCard()
    }
  }

  /// The hosts' and images' heading: caption, semibold, secondary.
  static func sectionTitle(_ text: String) -> some View {
    Text(text)
      .pinaxCaption()
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
  }

  /// A divider starting under the row's text, past its badge.
  static var rowDivider: some View {
    Divider().padding(.leading, rowInset + ColorSquare.Size.sidebar.side + DesignMetrics.spacing.s)
  }

  private func sourceRow(_ source: ExternalMigrationConfirmation.Source) -> some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(PinaxPalette.orange)
      Text(source.text)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: DesignMetrics.spacing.s)
      Toggle(
        "Write anyway",
        isOn: Binding(
          get: { model.migrationAllowedSources.contains(source.id) },
          set: { model.setMigrationSource(source.id, allowed: $0) }))
        .toggleStyle(.checkbox)
    }
    .padding(.horizontal, DesignMetrics.spacing.m)
    .padding(.vertical, DesignMetrics.spacing.s)
    .background(PinaxPalette.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

/// A summary row's value — figures medium, units secondary,
/// thin dividers between groups, a key's runs tinted, the storage's tag.
struct ExternalMigrationLineValue: View {
  let line: ExternalMigrationConfirmation.Line

  static func symbol(_ tone: ExternalMigrationConfirmation.Line.Tone) -> String {
    switch tone {
    case .upload: "arrow.up"
    case .reused: "equal"
    case .skipped: "exclamationmark"
    case .files: "pencil"
    case .bucket: "cylinder.fill"
    case .keys: "key.fill"
    }
  }

  /// The panel's tallies' hues for the same things (Upload, reused,
  /// skipped, files); Bucket orange and keys gray.
  static func color(_ tone: ExternalMigrationConfirmation.Line.Tone) -> Color {
    switch tone {
    // The badge's ground under a white glyph: the solid teal, as the
    // Inspector's Migrate button.
    case .upload: PinaxPalette.accentFill
    case .reused: ActivityEventStyle.tallyColor(.reused)
    case .skipped: ActivityEventStyle.tallyColor(.skipped)
    case .files: ActivityEventStyle.tallyColor(.filesChanged)
    case .bucket: PinaxPalette.orange
    case .keys: PinaxPalette.gray
    }
  }

  var body: some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      ForEach(Array(line.groups.enumerated()), id: \.offset) { index, group in
        if index > 0 {
          Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 12)
        }
        group.enumerated().reduce(Text("")) { text, item in
          text + Text(item.offset == 0 ? "" : item.element.gap) + styled(item.element)
        }
        .font(line.isMonospaced ? .system(.callout, design: .monospaced) : nil)
        .lineLimit(1)
        .truncationMode(.middle)
      }
      if let tag = line.tag {
        Text(tag)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(PinaxPalette.band, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      }
    }
    .help(line.value)
  }

  private func styled(_ segment: ExternalMigrationConfirmation.Line.Segment) -> Text {
    let text = Text(segment.text)
    if line.isWarning { return text.foregroundColor(PinaxPalette.orange) }
    switch segment.style {
    case .figure: return text.fontWeight(.medium).monospacedDigit()
    case .unit: return text.foregroundColor(.secondary)
    case .plain: return text
    case .faint: return text.foregroundColor(Color(nsColor: .tertiaryLabelColor))
    case .hash: return text.foregroundColor(PinaxPalette.accent)
    }
  }
}

/// "N Images · K over 1 MB", closed each time the sheet
/// opens; open, about six rows that scroll, largest first, with the total
/// pinned under them.
struct ExternalMigrationImageList: View {
  let confirmation: ExternalMigrationConfirmation
  @State private var isExpanded = false

  static let rowHeight = ExternalMigrationSheet.rowHeight
  static let visibleRows: CGFloat = 6

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
      } label: {
        // Headed like FROM N HOSTS, its text on the same edge; the
        // chevron follows the words.
        HStack(spacing: DesignMetrics.spacing.xs) {
          ExternalMigrationSheet.sectionTitle(confirmation.imagesTitle.uppercased())
          if let note = confirmation.imagesNote {
            Text("· \(note)")
              .pinaxCaption()
              .foregroundStyle(.secondary)
          }
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isExpanded {
        VStack(spacing: 0) {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(confirmation.images) { image in
                row(image)
                if image.id != confirmation.images.last?.id { ExternalMigrationSheet.rowDivider }
              }
            }
          }
          .frame(height: min(CGFloat(confirmation.images.count), Self.visibleRows) * Self.rowHeight)
          Divider()
          HStack {
            Text(PinaxFormat.count(confirmation.images.count, singular: "image"))
              .pinaxCaption()
              .foregroundStyle(.secondary)
            Spacer()
            ExternalSizeText(
              bytes: confirmation.imagesBytes, isLarge: false
            )
            .fontWeight(.medium)
          }
          .padding(.horizontal, ExternalMigrationSheet.rowInset)
          .frame(height: Self.rowHeight)
        }
        .migrationCard()
      }
    }
  }

  private func row(_ image: ExternalMigrationConfirmation.Image) -> some View {
    // The host's badge leads, as in the hosts list, so names, the caption
    // column and sizes fall on the same lines.
    HStack(spacing: DesignMetrics.spacing.s) {
      ExternalDomainSquare(host: image.host)
      Text(image.filename)
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(image.url)
      Text(image.host)
        .pinaxCaption()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      ExternalSizeText(bytes: image.bytes, isLarge: image.isLarge)
        .frame(width: DesignMetrics.externalsTable.sizeWidth, alignment: .trailing)
    }
    .padding(.horizontal, ExternalMigrationSheet.rowInset)
    .frame(height: Self.rowHeight)
  }
}

/// A group header's Migrate N… beside Load N, on hover.
struct ExternalGroupMigrateControl: View {
  let count: Int
  let isHovering: Bool
  let isBusy: Bool
  let migrate: () -> Void

  var body: some View {
    if isHovering, count > 0 {
      Button(action: migrate) {
        Label(ExternalsModel.migrateShortTitle(count), systemImage: ExternalsView.migrateSymbol)
          .labelStyle(.titleAndIcon)
          .fontWeight(.semibold)
          .lineLimit(1)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(PinaxPalette.accent)
      .controlSize(.small)
      .fixedSize()
      .disabled(isBusy)
      .help(isBusy ? ExternalsModel.migrationBusyHelp : "Migrate this group to your bucket")
    }
  }
}

extension View {
  /// The confirmation sheet's one card: band fill, 10 pt corners, clipped.
  fileprivate func migrationCard() -> some View {
    background(PinaxPalette.band, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
