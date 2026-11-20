import CatalogCore
import SwiftUI

/// A flat inspector group: a small gray title over its rows. The
/// library's inspector and Externals' draw theirs with it.
struct InspectorGroup<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
      Text(title)
        .pinaxSectionTitle()
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A label over its value; an absent value is the placeholder dash, so
/// the row keeps its shape loaded and unloaded.
struct InspectorField<Value: View>: View {
  let title: String
  let value: Value

  init(_ title: String, @ViewBuilder value: () -> Value) {
    self.title = title
    self.value = value()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      Text(title)
        .pinaxCaption()
      value
    }
  }
}

// MARK: - Collapsible sections

/// A collapsible inspector section: a `SectionBand` over its rows.
/// Each band remembers whether it is open per window (`@SceneStorage`,
/// under `storageKey`), so a band closed once stays closed across
/// selections and relaunches. Opening and closing is immediate.
struct InspectorBandSection<Content: View>: View {
  let title: String
  /// A figure at the band's trailing end (Usage's Used In count).
  let count: String?
  let content: Content
  /// An optional figure at the band's trailing end (Externals' Used In
  /// count).
  let trailing: String?
  @SceneStorage private var isExpanded: Bool

  init(
    _ title: String, storageKey: String, expandedByDefault: Bool = true,
    count: String? = nil, trailing: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.count = count
    self.content = content()
    self.trailing = trailing
    self._isExpanded = SceneStorage(wrappedValue: expandedByDefault, storageKey)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.none) {
      SectionBand(title, isExpanded: $isExpanded, trailing: trailing ?? count)
      if isExpanded {
        content
          .padding(.top, DesignMetrics.inspectorFields.topPadding)
          .padding(.horizontal, DesignMetrics.inspectorFields.horizontalPadding)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A band's two-column rows: keys 48 wide, right-aligned, with a colon.
struct InspectorFieldGrid<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: DesignMetrics.inspectorFields.columnSpacing,
      verticalSpacing: DesignMetrics.inspectorFields.rowSpacing
    ) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One key and its value in an `InspectorFieldGrid`; a nil key leaves the
/// key column empty (the link row's second line).
struct InspectorFieldRow<Value: View>: View {
  let key: String?
  let value: Value

  init(_ key: String?, @ViewBuilder value: () -> Value) {
    self.key = key
    self.value = value()
  }

  /// "Source" reads "Source:".
  static func keyText(_ key: String) -> String { key + ":" }

  var body: some View {
    GridRow(alignment: .center) {
      Group {
        if let key {
          Text(Self.keyText(key))
            .pinaxFieldKey()
            .lineLimit(1)
        } else {
          Color.clear.frame(height: 0)
        }
      }
      .frame(width: DesignMetrics.inspectorFields.keyWidth, alignment: .trailing)
      value
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The seven Finder labels as one seamless band: a
/// segment per label, equal widths, 18 high, corner 6. A label every
/// selected item has is full with a check, one only some have is full with
/// a dash, and while any is on the rest drop to 35 %. A click toggles that
/// label, exactly as the old dots did.
struct LabelBand: View {
  let states: [AssetLabel: Bool?]
  let onToggle: (AssetLabel) -> Void

  /// A segment's opacity: all full while none is on.
  static func opacity(of state: Bool?, anyOn: Bool) -> Double {
    guard anyOn else { return 1 }
    return state == false ? DesignMetrics.labelBand.dimmedOpacity : 1
  }

  /// The mark on a segment: a check when all have it, a dash when some do.
  static func mark(of state: Bool?) -> String? {
    switch state {
    case true?: return "checkmark"
    case nil: return "minus"
    case false?: return nil
    }
  }

  static func anyOn(_ states: [AssetLabel: Bool?]) -> Bool {
    states.values.contains { $0 != false }
  }

  var body: some View {
    let anyOn = Self.anyOn(states)
    HStack(spacing: DesignMetrics.spacing.none) {
      ForEach(AssetLabel.allCases, id: \.self) { label in
        let state = states[label] ?? false
        Button {
          onToggle(label)
        } label: {
          ZStack {
            Rectangle().fill(label.color)
            if let mark = Self.mark(of: state) {
              Image(systemName: mark)
                .pinaxGlyph(DesignMetrics.labelBand.check, weight: .heavy)
                .foregroundStyle(.white)
            }
          }
          .opacity(Self.opacity(of: state, anyOn: anyOn))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label.title)
        .accessibilityLabel(label.title)
        .accessibilityAddTraits(state == true ? .isSelected : [])
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: DesignMetrics.labelBand.height)
    .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.labelBand.radius, style: .continuous))
  }
}

/// The inspector's title (InspectorBar option 2): the format square and
/// the file over "date · kind", drawn by the inspector column in the strip
/// it has under the window toolbar, so it shares the row with the toolbar's
/// inspector toggle instead of drawing a second bar under it. Being the
/// column's own view, it opens and closes with the column, cut off by the
/// main pane as the content is. Empty when no single asset or reference is
/// shown.
struct InspectorTitleBar: View {
  @ObservedObject var model: GalleryModel

  /// The single asset whose title shows, if any.
  static func details(_ model: GalleryModel) -> CatalogAssetDetails? {
    guard model.showsAssetSelection, model.shownSelection != .externals,
      model.selectedIDs.count <= 1
    else { return nil }
    return model.selectedDetails
  }

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: DesignMetrics.inspectorHeader.spacing) {
        if let details = Self.details(model) {
          let title = AssetInspectorView.headerTitle(details)
          FormatSquare(mime: details.item.asset.mime)
          VStack(alignment: .leading, spacing: DesignMetrics.inspectorHeader.titleSpacing) {
            Text(title.title)
              .pinaxInspectorTitle()
              .lineLimit(1)
              .truncationMode(.middle)
            Text(title.subtitle)
              .pinaxSecondary()
              .lineLimit(1)
          }
        } else if model.shownSelection == .externals {
          // The one selected reference's square, name and
          // "On another host · domain". The nested model is what changes
          // when a row is selected, so it is its own observer.
          ExternalInspectorTitle(externals: model.externals)
        }
      }
      // Clear of the toggle at the strip's trailing end.
      .frame(maxWidth: DesignMetrics.inspectorHeader.width, alignment: .leading)
      .padding(.leading, DesignMetrics.inspectorHeader.leadingInset)
      // The strip is the column's top safe-area inset (the toolbar's
      // height), read here inside the safe area: a reader that ignores it
      // is told 0 (measured). The title is then lifted into the strip.
      .frame(
        width: GalleryWidthBudget.inspectorWidth, height: proxy.safeAreaInsets.top,
        alignment: .leading)
      .frame(width: proxy.size.width, alignment: .leading)
      .clipped()
      .offset(y: -proxy.safeAreaInsets.top)
    }
    // Under the toolbar; the toggle and window drags keep their clicks.
    .allowsHitTesting(false)
  }
}

/// Externals' half of the inspector title: the reference's
/// format square, its file name and "On another host · domain".
struct ExternalInspectorTitle: View {
  @ObservedObject var externals: ExternalsModel

  static func row(_ externals: ExternalsModel) -> ExternalReference? {
    guard externals.selection.count == 1 else { return nil }
    return externals.rows(externals.selection).first
  }

  var body: some View {
    if let row = Self.row(externals) {
      FormatSquare(mime: ExternalsView.mime(row))
      VStack(alignment: .leading, spacing: DesignMetrics.inspectorHeader.titleSpacing) {
        Text(ExternalsView.filename(row))
          .pinaxInspectorTitle()
          .lineLimit(1)
          .truncationMode(.middle)
        Text(
          ExternalsView.headerSubtitle(row, failure: externals.importFailure(row))
        )
        .pinaxSecondary()
        .lineLimit(1)
      }
    } else if externals.selection.count > 1,
      let summary = externals.selectionSummary(externals.selection)
    {
      // "3 Images" over "2 hosts · 3 files".
      ColorSquare(
        size: .sidebar, color: PinaxPalette.accent,
        content: .symbol(ExternalsView.selectionSymbol))
      VStack(alignment: .leading, spacing: DesignMetrics.inspectorHeader.titleSpacing) {
        Text(PinaxFormat.count(summary.images.count, singular: "Image"))
          .pinaxInspectorTitle()
          .lineLimit(1)
        Text(summary.facts)
          .pinaxSecondary()
          .lineLimit(1)
      }
    }
  }
}
