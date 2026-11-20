import CatalogCore
import AppKit
import SwiftUI

/// The activity panel: Xcode's
/// debug area. It rises under the status bar — the bar stays its top bar;
/// left the runs, right the log, and a bottom bar across both. Its
/// height drags at the bar's top edge (`ActivityPanelResizeHandle`), the
/// run list's width at its divider, each remembered per window.
struct ActivityPanelView: View {
  @ObservedObject var model: ActivityPanelModel
  /// `@SceneStorage("activityRunListWidth")`, unclamped.
  @Binding var runListWidth: Double

  @State private var panelWidth: CGFloat = 0
  @State private var dragStart: CGFloat?
  @State private var hoveringDivider = false

  static let filterWidth: CGFloat = 240
  static let filterMinWidth: CGFloat = 80
  static let animation = Animation.easeInOut(duration: 0.2)
  static let handleThickness: CGFloat = 6

  private var shownRunListWidth: CGFloat {
    ActivityPanelModel.clampedRunListWidth(CGFloat(runListWidth), panelWidth: panelWidth)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        if model.showsRunList {
          ActivityRunList(model: model)
            .frame(width: shownRunListWidth)
          Divider()
            .overlay { runListDivider }
        }
        ActivityLog(model: model)
          .frame(maxWidth: .infinity)
      }
      .frame(maxHeight: .infinity)
      ActivityPanelBar(model: model)
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
    .overlay(alignment: .top) { Divider() }
    .sheet(
      isPresented: Binding(
        get: { model.changesDiff != nil },
        set: { if !$0 { model.changesDiff = nil } })
    ) {
      ChangesDiffSheet(text: model.changesDiff ?? "") { model.changesDiff = nil }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("activity-panel")
  }

  /// The divider's wider, invisible grip.
  private var runListDivider: some View {
    Color.clear
      .frame(width: Self.handleThickness)
      .contentShape(Rectangle())
      .onHover { inside in
        guard inside != hoveringDivider else { return }
        hoveringDivider = inside
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let origin = dragStart ?? shownRunListWidth
            dragStart = origin
            runListWidth = Double(
              ActivityPanelModel.clampedRunListWidth(origin + drag.translation.width, panelWidth: panelWidth))
          }
          .onEnded { _ in dragStart = nil })
      .accessibilityHidden(true)
  }
}

/// The panel's top edge — the status bar's — drags its height.
struct ActivityPanelResizeHandle: View {
  /// `@SceneStorage("activityPanelHeight")`, unclamped.
  @Binding var height: Double
  let windowHeight: CGFloat

  @State private var dragStart: CGFloat?
  @State private var hovering = false

  var body: some View {
    Color.clear
      .frame(height: ActivityPanelView.handleThickness)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .offset(y: -ActivityPanelView.handleThickness / 2)
      .onHover { inside in
        guard inside != hovering else { return }
        hovering = inside
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let origin = dragStart
              ?? ActivityPanelModel.clampedHeight(CGFloat(height), windowHeight: windowHeight)
            dragStart = origin
            height = Double(
              ActivityPanelModel.clampedHeight(origin - drag.translation.height, windowHeight: windowHeight))
          }
          .onEnded { _ in dragStart = nil })
      .accessibilityHidden(true)
  }
}

/// The runs, grouped by day.
private struct ActivityRunList: View {
  @ObservedObject var model: ActivityPanelModel

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(model.groups, id: \.title) { group in
          Text(group.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 3)
          ForEach(group.rows) { row in
            runRow(row)
          }
        }
      }
      .padding(.vertical, 6)
    }
  }

  private func runRow(_ row: ActivityRunRow) -> some View {
    let selected = row.id == model.selectedRunID
    return HStack(spacing: 7) {
      ActivityRunGlyph(row: row)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(ActivityRunGlyph.color(row)))
      // The action primary, the rest secondary.
      (Text(row.action)
        + Text(row.subject.map { " \($0)" } ?? "")
        .foregroundColor(selected ? .white.opacity(0.75) : .secondary))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(row.name)
      Text(row.time)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
    }
    .font(.callout)
    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    .padding(.horizontal, 8)
    .frame(height: 26)
    .background(
      RoundedRectangle(cornerRadius: 5).fill(selected ? AnyShapeStyle(PinaxPalette.accentFill) : AnyShapeStyle(.clear))
    )
    .contentShape(Rectangle())
    .padding(.horizontal, 6)
    .onTapGesture { model.selectedRunID = row.id }
    .contextMenu {
      Button("Copy Log") { Task { await model.copyLog(ofRun: row.id) } }
    }
  }
}

private struct ActivityRunGlyph: View {
  let row: ActivityRunRow

  static func symbol(_ row: ActivityRunRow) -> String {
    switch row.state {
    case .running: return "arrow.triangle.2.circlepath.circle.fill"
    case .finished: return row.hasWarnings ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    case .failed, .cancelled: return "xmark.circle.fill"
    case .interrupted: return "exclamationmark.circle.fill"
    }
  }

  static func color(_ row: ActivityRunRow) -> AnyShapeStyle {
    switch row.state {
    case .running: return AnyShapeStyle(PinaxPalette.accent)
    case .finished: return AnyShapeStyle(row.hasWarnings ? Color.orange : Color.green)
    case .failed: return AnyShapeStyle(Color.red)
    case .cancelled: return AnyShapeStyle(.secondary)
    case .interrupted: return AnyShapeStyle(Color.orange)
    }
  }

  var body: some View {
    Image(systemName: Self.symbol(row))
      .help(row.state == .interrupted ? "Interrupted" : row.state.rawValue.capitalized)
  }
}

/// The header, then Events or Raw.
private struct ActivityLog: View {
  @ObservedObject var model: ActivityPanelModel
  @FocusState private var logFocused: Bool

  var body: some View {
    if model.runs.isEmpty {
      Text("No activity yet")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        header
        Divider()
        switch model.logView {
        case .events: events
        case .raw: raw
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Text(model.title ?? "")
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(model.title ?? "")
      ForEach(model.tallies, id: \.kind) { tally in
        HStack(spacing: 4) {
          Image(systemName: ActivityEventStyle.tallySymbol(tally.kind))
            .foregroundStyle(ActivityEventStyle.tallyColor(tally.kind))
          Text(tally.count.formatted())
            .monospacedDigit()
        }
        .font(.callout.weight(.semibold))
        .help(tally.kind.help)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 36)
  }

  /// Rows select like a list — click, ⇧ range, ⌘ add or remove —
  /// and ⌘C or the row's Copy copies them.
  private var events: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(model.eventSections, id: \.records.first?.seq) { section in
          if let title = section.title {
            ActivityLogHeading(title: title)
          }
          ForEach(section.records, id: \.seq) { record in
            let selected = model.selectedLines.contains(record.seq)
            ActivityLogRow(record: record, selected: selected)
              .padding(.horizontal, 8)
              .frame(height: 22)
              .background(selectionPlate(selected))
              .padding(.horizontal, 6)
              .modifier(LogRowSelecting(model: model, seq: record.seq, focus: $logFocused))
          }
        }
      }
      .padding(.top, 4)
    }
    .modifier(LogCopying(model: model, focus: $logFocused))
  }

  /// Raw scrolls sideways so a long line shows whole; every row is
  /// as wide as the longest, so a selected row's plate spans the line.
  private var raw: some View {
    let rows = model.rawRows
    return GeometryReader { proxy in
      let width = max(proxy.size.width, Self.rawWidth(rows.map(\.line)) + 2 * 14)
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows, id: \.seq) { row in
            let selected = model.selectedLines.contains(row.seq)
            Text(row.line)
              .font(Self.rawFont)
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
              .padding(.horizontal, 8)
              .frame(width: width - 12, height: 18, alignment: .leading)
              .background(selectionPlate(selected))
              .padding(.horizontal, 6)
              .modifier(LogRowSelecting(model: model, seq: row.seq, focus: $logFocused))
          }
        }
        .padding(.vertical, 4)
      }
    }
    .modifier(LogCopying(model: model, focus: $logFocused))
  }

  static let rawFont = Font.system(size: 11, design: .monospaced)

  /// The widest raw line, measured on the longest few (monospaced, so
  /// length tracks width but for wide characters).
  static func rawWidth(_ lines: [String]) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    return lines.sorted { $0.utf16.count > $1.utf16.count }.prefix(20)
      .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
      .max() ?? 0
  }

  private func selectionPlate(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5).fill(selected ? AnyShapeStyle(PinaxPalette.accentFill) : AnyShapeStyle(.clear))
  }
}

/// A heading that says what was done, then a hairline.
private struct ActivityLogHeading: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
      Rectangle()
        .fill(.separator)
        .frame(height: 1)
    }
    .padding(.horizontal, 14)
    .frame(height: 22)
  }
}

/// One event on one line, in four layers — the verb (label),
/// the object (monospaced, a size down, secondary; truncated first), the
/// detail (tertiary, whole; a large size orange) and the time (monospaced,
/// quaternary). A planned step is a level down; the summary's verb is
/// the only bold one. Selected, the layers are white at falling opacity.
private struct ActivityLogRow: View {
  let record: RunEventRecord
  let selected: Bool

  var body: some View {
    let parts = record.event.summaryParts
    let style = ActivityEventStyle(record)
    let planned = ActivityPanelModel.isPlanned(record.event)
    HStack(spacing: 7) {
      Image(systemName: style.symbol)
        .foregroundStyle(
          selected ? AnyShapeStyle(.white) : planned ? AnyShapeStyle(.tertiary) : AnyShapeStyle(style.color))
      if parts.objectFirst, let object = parts.object {
        objectText(object)
        verb(parts.verb, planned: planned)
      } else {
        verb(parts.verb, planned: planned)
        if let object = parts.object { objectText(object) }
      }
      Spacer(minLength: 0)
      if let detail = parts.detail {
        Text(detail)
          .monospacedDigit()
          .foregroundStyle(detailStyle)
          .lineLimit(1)
          .fixedSize()
      }
      Text(ActivityPanelModel.eventTime(record.at))
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(layer(0.6, .quaternary))
        .fixedSize()
    }
    .font(.callout)
    .help(record.event.summaryLine)
  }

  private func verb(_ text: String, planned: Bool) -> some View {
    Text(text)
      .fontWeight(ActivityPanelModel.isSummary(record.event) ? .semibold : .regular)
      .foregroundStyle(layer(1, planned ? .secondary : .primary))
      .lineLimit(1)
      .fixedSize()
  }

  private func objectText(_ text: String) -> some View {
    Text(text)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(layer(0.85, .secondary))
      .lineLimit(1)
      .truncationMode(.middle)
      .layoutPriority(-1)
  }

  private var detailStyle: AnyShapeStyle {
    if ActivityPanelModel.hasLargeDetail(record.event), !selected { return AnyShapeStyle(PinaxPalette.orange) }
    return layer(0.75, .tertiary)
  }

  private func layer(_ opacity: Double, _ style: HierarchicalShapeStyle) -> AnyShapeStyle {
    selected ? AnyShapeStyle(.white.opacity(opacity)) : AnyShapeStyle(style)
  }
}

/// A log row's click (with ⇧ / ⌘ read off the event) and its
/// context menu's Copy.
private struct LogRowSelecting: ViewModifier {
  let model: ActivityPanelModel
  let seq: Int
  var focus: FocusState<Bool>.Binding

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      // The modifiers are declared on the gestures,
      // not read off `NSEvent.modifierFlags` in a plain tap.
      .gesture(Self.click { extending, toggling in
        model.clickLine(seq, extending: extending, toggling: toggling)
        focus.wrappedValue = true
      })
      .contextMenu {
        Button("Copy") { model.copyLines(from: seq) }
      }
  }

  /// ⌘⇧, ⌘, ⇧, then a plain click, the first that matches.
  static func click(_ action: @escaping (_ extending: Bool, _ toggling: Bool) -> Void) -> some Gesture {
    TapGesture().modifiers([.command, .shift]).onEnded { action(true, true) }
      .exclusively(before: TapGesture().modifiers(.command).onEnded { action(false, true) })
      .exclusively(before: TapGesture().modifiers(.shift).onEnded { action(true, false) })
      .exclusively(before: TapGesture().onEnded { action(false, false) })
  }
}

/// The log takes focus on a click, so Edit ▸ Copy (⌘C) reaches it.
private struct LogCopying: ViewModifier {
  let model: ActivityPanelModel
  var focus: FocusState<Bool>.Binding

  func body(content: Content) -> some View {
    content
      // `.edit`: a click focuses it whatever the Keyboard Navigation
      // setting, so ⌘A / ⌘C reach it.
      .focusable(interactions: .edit)
      .focusEffectDisabled()
      .focused(focus)
      .onCommand(#selector(NSText.copy(_:))) { model.copySelectedLines() }
      .onCommand(#selector(NSText.selectAll(_:))) { model.selectAllLines() }
  }
}

/// View, warnings only, Filter, three icon buttons, the run list.
private struct ActivityPanelBar: View {
  @ObservedObject var model: ActivityPanelModel

  var body: some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      Menu {
        Picker("Log", selection: $model.logView) {
          ForEach(ActivityLogView.allCases, id: \.self) { view in
            Text(view.title).tag(view)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        HStack(spacing: 4) {
          Text(model.logView.title)
          Image(systemName: "chevron.up.chevron.down")
            .imageScale(.small)
        }
        .font(.caption)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()

      barDivider

      Button {
        model.warningsOnly.toggle()
      } label: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(model.warningsOnly ? AnyShapeStyle(PinaxPalette.accent) : AnyShapeStyle(.secondary))
      .help("Warnings and errors only")

      Spacer(minLength: 0)

      TextField("Filter", text: $model.filter)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        // 240 when there is room, down to 80 in a narrow column.
        .frame(minWidth: ActivityPanelView.filterMinWidth, idealWidth: ActivityPanelView.filterWidth,
          maxWidth: ActivityPanelView.filterWidth)
        .layoutPriority(-1)

      barDivider

      Button {
        model.showsChangedFiles = true
      } label: {
        Image(systemName: "doc.text.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help(
        model.isPreviewSelected
          ? "Files this preview would change" : "Files this run changed")
      .disabled(model.changedFiles.isEmpty)
      .popover(isPresented: $model.showsChangedFiles, arrowEdge: .top) {
        ActivityChangedFiles(model: model)
      }

      Button {
        model.revealChangedFiles()
      } label: {
        Image(systemName: "folder.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Reveal the changed files in Finder")
      .disabled(model.changedFileURLs.isEmpty)

      Button {
        model.copyLog()
      } label: {
        Image(systemName: "doc.on.doc.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help(model.logView == .events ? "Copy the log as shown" : "Copy the JSONL as shown")
      .disabled(model.selectedRun == nil)

      barDivider

      Button {
        withAnimation(ActivityPanelView.animation) { model.showsRunList.toggle() }
      } label: {
        Image(systemName: "rectangle.leftthird.inset.filled")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(model.showsRunList ? AnyShapeStyle(PinaxPalette.accent) : AnyShapeStyle(.secondary))
      .help(model.showsRunList ? "Hide the run list" : "Show the run list")
    }
    .padding(.horizontal, ChromeMetrics.horizontalPadding)
    .frame(height: ChromeMetrics.barHeight)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  private var barDivider: some View {
    Divider().frame(height: 16)
  }
}

/// Changed Files: an apply's `changed_files_by_repo`, by repository (a
/// file opens); a preview's planned files, by project · source, and Show
/// Changes…
private struct ActivityChangedFiles: View {
  @ObservedObject var model: ActivityPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(model.changedFiles, id: \.title) { repository in
            Text(repository.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .padding(.top, 4)
            ForEach(repository.paths, id: \.self) { path in
              if repository.root == nil {
                Text(path)
                  .foregroundStyle(repository.planned == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .help(path)
              } else {
                Button(path) {
                  if let url = repository.url(path) { model.open(url) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(PinaxPalette.accent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
              }
            }
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 320)
      if model.canShowChanges {
        Divider()
        HStack {
          Spacer()
          Button("Show Changes…") {
            Task { await model.showChanges() }
          }
          .buttonStyle(.plain)
          .fontWeight(.semibold)
          .foregroundStyle(PinaxPalette.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
    .frame(width: 360)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// An event's `.fill` symbol and semantic colour: warnings and
/// errors by level, the rest by type.
/// The blues are the project's teal (`accent`, which has a dark value) and
/// gruvbox aqua / blue, never the system accent.
struct ActivityEventStyle {
  let symbol: String
  let color: Color

  init(_ record: RunEventRecord) {
    switch record.level {
    case .error:
      (symbol, color) = ("xmark.circle.fill", .red)
      return
    case .warning:
      (symbol, color) = ("exclamationmark.circle.fill", .orange)
      return
    case .info:
      break
    }
    switch record.event {
    case .runStarted, .migrationStarted: (symbol, color) = ("play.circle.fill", PinaxPalette.accent)
    case .downloadFinished: (symbol, color) = ("arrow.down.circle.fill", PinaxPalette.accent)
    case .uploadFinished: (symbol, color) = ("arrow.up.circle.fill", PinaxPalette.accent)
    case .assetReused: (symbol, color) = ("equal.circle.fill", PinaxPalette.aqua)
    case .fileWritten: (symbol, color) = ("pencil.circle.fill", .purple)
    case .rescanFinished: (symbol, color) = ("arrow.clockwise.circle.fill", .green)
    case .runFinished, .targetVerified: (symbol, color) = ("checkmark.circle.fill", .green)
    case .prefixChanged, .keyChanged: (symbol, color) = ("arrow.left.arrow.right.circle.fill", PinaxPalette.blue)
    default: (symbol, color) = ("info.circle.fill", .secondary)
    }
  }

  static func tallySymbol(_ kind: ActivityTally.Kind) -> String {
    switch kind {
    case .uploaded: return "arrow.up.circle.fill"
    case .reused: return "equal.circle.fill"
    case .skipped: return "exclamationmark.circle.fill"
    case .filesChanged: return "pencil.circle.fill"
    case .failed: return "xmark.circle.fill"
    }
  }

  static func tallyColor(_ kind: ActivityTally.Kind) -> Color {
    switch kind {
    case .uploaded: return PinaxPalette.accent
    case .reused: return PinaxPalette.aqua
    case .skipped: return .orange
    case .filesChanged: return .purple
    case .failed: return .red
    }
  }
}
