import CatalogCore
import SwiftUI

/// The Externals page's ⓘ, its
/// first-visit card, its sort menu, Group by File and the grouped list's
/// column headers.

/// The jump bar's sort menu on Externals: the four
/// fields, then the order — the gallery menu's shape over the page's own
/// `sort`.
struct ExternalSortMenuItems: View {
  @ObservedObject var externals: ExternalsModel

  /// The one state the menu and the column headers write.
  var sort: Binding<ExternalSort> { $externals.sort }

  var body: some View {
    Picker("Sort By", selection: sort.field) {
      ForEach(ExternalSort.Field.allCases, id: \.self) { field in
        Text(Self.title(field)).tag(field)
      }
    }
    .pickerStyle(.inline)
    .labelsHidden()

    Divider()

    Picker("Order", selection: sort.direction) {
      Text("Ascending").tag(AssetSort.Direction.ascending)
      Text("Descending").tag(AssetSort.Direction.descending)
    }
    .pickerStyle(.inline)
    .labelsHidden()
  }

  /// The menu's names: Status says which end the problems are at.
  static func title(_ field: ExternalSort.Field) -> String {
    field == .status ? "Status (problems first)" : ExternalSort.title(field)
  }
}

/// The jump bar's grouping control on Externals: a "Group: Host ⌄" pop-up.
struct ExternalsGroupByFileToggle: View {
  @ObservedObject var externals: ExternalsModel
  let state: JumpBar.ControlState

  /// The pop-up's name for a grouping — Host on Other
  /// Domains, Domain on Your Domains, Used In for the files.
  static func option(byFile: Bool, domain: ExternalDomain) -> String {
    byFile ? "Used In" : (domain == .yours ? "Domain" : "Host")
  }

  /// "Group: Host".
  static func title(byFile: Bool, domain: ExternalDomain) -> String {
    "Group: \(option(byFile: byFile, domain: domain))"
  }

  var body: some View {
    // A labelled pop-up, Xcode's borderless kind, over the same
    // `groupsByFile` and its stored preference.
    Menu {
      Picker("Group", selection: $externals.groupsByFile) {
        Text(Self.option(byFile: false, domain: externals.domain)).tag(false)
        Text(Self.option(byFile: true, domain: externals.domain)).tag(true)
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HStack(spacing: DesignMetrics.spacing.xs) {
        Image(systemName: state.control.systemImage)
        ChromeMetrics.text(Self.title(byFile: externals.groupsByFile, domain: externals.domain))
        Image(systemName: JumpBar.currentIndicator)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      .fixedSize()
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .foregroundStyle(.secondary)
    .help(state.help)
  }
}

/// ⓘ beside the header's summary: a popover with a
/// sentence for each half and one line of facts.
struct ExternalsInfoButton: View {
  @ObservedObject var model: ExternalsModel
  @State private var isShown = false

  static let symbol = "info.circle"

  var body: some View {
    Button {
      isShown.toggle()
    } label: {
      Label("About Externals", systemImage: Self.symbol)
        .labelStyle(.iconOnly)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help("About Externals")
    .popover(isPresented: $isShown, arrowEdge: .bottom) {
      ExternalsInfoView(info: model.info)
    }
  }
}

struct ExternalsInfoView: View {
  let info: ExternalsInfo

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      ForEach(Array(info.notes.enumerated()), id: \.offset) { _, note in
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
          if let heading = note.heading {
            Text(heading)
              .pinaxSectionTitle()
          }
          ForEach(note.lines, id: \.self) { line in
            Text(line)
              .pinaxSecondary()
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      Divider()
      Text(info.facts)
        .pinaxCaption()
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }
    .textSelection(.enabled)
    .padding(DesignMetrics.spacing.l)
    .frame(width: DesignMetrics.externals.infoWidth, alignment: .leading)
  }
}

/// The first-visit card, as the import summary's bar
/// under the header: closed with ✕, it never comes back, in any project.
struct ExternalsTipBar: View {
  @ObservedObject var model: ExternalsModel

  static let symbol = "square.and.arrow.down.on.square"

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.m) {
      Image(systemName: Self.symbol)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
        Text(ExternalsTip.title)
          .pinaxSectionTitle()
          .foregroundStyle(.primary)
        Text(ExternalsTip.message)
          .pinaxSecondary()
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: DesignMetrics.spacing.m)
      if model.showsImportAll {
        Button("Import All…") { Task { await model.requestImportAll() } }
          .disabled(!model.isImportAllEnabled)
      }
      Button {
        model.dismissTip()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Close")
    }
    .controlSize(.small)
    .padding(.horizontal, ChromeMetrics.horizontalPadding)
    .padding(.vertical, DesignMetrics.spacing.s)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
}

/// The grouped list's column headers:
/// Host, Used In, Kind, Refs over the rows' columns. A click sorts — the
/// same `sort` the jump bar's menu writes. Which control: `Table` has
/// clickable headers, but the list is our flat pair of row kinds;
/// a `Table` would redo it. So the arrangement is ours, and each header is
/// a plain button.
struct ExternalsListHeader: View {
  @ObservedObject var model: ExternalsModel
  @Environment(\.externalsShowsUsedIn) private var showsUsedIn
  @Environment(\.externalsShowsSize) private var showsSize

  static let columns: [ExternalSort.Field] = [.name, .usedIn, .kind, .refs]

  /// A header's click.
  func click(_ field: ExternalSort.Field) {
    model.sort = model.sort.clicking(field)
  }

  /// The arrow a header draws: the shown column's direction, else none.
  func indicator(_ field: ExternalSort.Field) -> String? {
    guard model.sort.field == field else { return nil }
    return model.sort.direction == .ascending ? "chevron.up" : "chevron.down"
  }

  /// The header's words: Host where the sort field is the
  /// row's Name.
  static func title(_ field: ExternalSort.Field) -> String {
    field == .name ? "Host" : ExternalSort.title(field)
  }

  var body: some View {
    HStack(spacing: DesignMetrics.externalsTable.headerSpacing) {
      header(.name)
        .frame(maxWidth: .infinity, alignment: .leading)
      if showsUsedIn {
        header(.usedIn)
          .frame(width: DesignMetrics.externalsTable.usedInWidth, alignment: .leading)
      }
      header(.kind)
        .frame(width: DesignMetrics.externalsTable.kindWidth)
      if showsSize {
        // Not a sort field; the header only names it.
        Text("Size")
          .pinaxTableHeader()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(width: DesignMetrics.externalsTable.sizeWidth, alignment: .trailing)
      }
      header(.refs)
        .frame(width: DesignMetrics.externalsTable.refsWidth, alignment: .trailing)
    }
    .padding(.leading, DesignMetrics.externalsTable.headerLeading)
    .padding(.trailing, DesignMetrics.externalsTable.headerTrailing)
    .frame(height: DesignMetrics.externalsTable.headerHeight)
    // The header sits on the table's own ground.
    .background(PinaxPalette.windowGround)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func header(_ field: ExternalSort.Field) -> some View {
    Button {
      click(field)
    } label: {
      HStack(spacing: DesignMetrics.externalsTable.segmentSpacing) {
        Text(Self.title(field))
        if let symbol = indicator(field) {
          Image(systemName: symbol)
            .imageScale(.small)
        }
      }
      .pinaxTableHeader()
      .fontWeight(model.sort.field == field ? .semibold : .regular)
      .foregroundStyle(model.sort.field == field ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .lineLimit(1)
    }
    .buttonStyle(.plain)
  }
}
