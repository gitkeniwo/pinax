import CatalogCore
import SwiftUI

/// The in-content find strip: Safari/Xcode's ⌘F bar idiom —
/// a few shared-border control groups sitting inside the content area, not
/// a row of loose controls. Extracted from `GalleryView` so its height
/// invariance is assertable by hosting this view alone.
///
/// Why the grouping is ours and nothing else is: AppKit's
/// real find bar is `NSTextFinder` + a scroll view's `findBarPosition`,
/// and it searches TEXT IN A TEXT VIEW. Pinax's filter is a SQL predicate
/// over a catalog — `NSTextFinder` cannot express it, and bending the
/// gallery into a text view to borrow its chrome would be far worse
/// than building the arrangement. Every CONTROL here is
/// standard (TextField, Toggle, Picker, Button); only the grouping is
/// bespoke.
///
/// There are deliberately no previous /
/// next-result buttons. Pinax removes nonmatching assets instead of
/// highlighting matches in place, so every visible asset is already a match
/// and there is no distinct "next match" to navigate to.
///
/// Which grouping API, measured in the running app on this OS (15.7.8):
/// `ControlGroup` JOINS button-like content — two buttons share one
/// continuous capsule, automatic and navigation styles alike — but a
/// `TextField` or a menu-style `Picker` put inside it ESCAPES the group:
/// the group renders as an `NSSegmentedControl` over the remaining items
/// while the field/popup is hosted as a sibling outside the capsule. A
/// strip built around a field and a mode popup is therefore mixed
/// content and uses the per-group container — `.background(.quaternary,
/// in: RoundedRectangle(cornerRadius: 6))` with `Divider()`s between
/// segments — which measured as properly joined. The fallback is chosen
/// by measurement, not by preference.
struct FindStrip: View {
  @ObservedObject var model: GalleryModel
  @FocusState private var fieldFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      fieldGroup
      matchGroup
      scopePicker
      sourcePicker
      if !appliesHere {
        Text("Not used here")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
    .controlSize(.small)
    .padding(.horizontal, ChromeMetrics.horizontalPadding)
    .frame(height: ChromeMetrics.stripHeight)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    // ⌘F presents the strip; the task fires on every change of that flag,
    // including the strip's own appearance, and focuses the field.
    .task(id: model.isSearchPresented) {
      if model.isSearchPresented {
        fieldFocused = true
      }
    }
    // Escape must win against the field editor's own cancelOperation —
    // `onKeyPress` measurably never fires for it — so the strip installs a
    // local key monitor, scoped to the filter field's focus state.
    .background(
      EscapeMonitor(focus: $fieldFocused) {
        model.searchText = ""
        model.sourceFilter = nil
        model.isSearchPresented = false
      }
    )
  }

  // MARK: - Groups

  /// Field group: magnifier + field + clear in one capsule.
  private var fieldGroup: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(
        "Filter", text: searchTextBinding,
        prompt: Text("Search filename, key, note")
      )
      .textFieldStyle(.plain)
      .focused($fieldFocused)
      .frame(minWidth: 180)
      if !model.searchText.isEmpty {
        Button {
          model.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Clear the filter text")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .frame(maxWidth: 360, alignment: .leading)
    .help(
      appliesHere
        ? "Filters the current view. Scopes select which columns match."
        : "The filter applies to asset views; this report does not use it.")
  }

  /// Match group: case toggle + mode popup in one capsule. The controls
  /// stay PRESENT on the report surfaces, disabled in place (chrome does
  /// not reflow between selections; only the caveat text says the rest). Disabled controls never touch the field's
  /// focus — that was the measured failure of disabling the field itself.
  private var matchGroup: some View {
    HStack(spacing: 0) {
      Toggle("Aa", isOn: caseSensitiveBinding)
        .toggleStyle(.button)
        .fixedSize()
        .accessibilityLabel("Match case")
        .help("Distinguish upper and lower case while matching")
      Divider()
        .frame(height: 14)
        .padding(.horizontal, 2)
      Picker("Match mode", selection: matchModeBinding) {
        Text("Contains").tag(SearchMatch.contains)
        Text("Begins with").tag(SearchMatch.begins)
        Text("Ends with").tag(SearchMatch.ends)
        Text("Matches").tag(SearchMatch.matches)
      }
      .pickerStyle(.menu)
      .fixedSize()
      .labelsHidden()
      .help("How the text must appear in the matching columns")
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .disabled(!appliesHere)
  }

  private var scopePicker: some View {
    Picker("Scope", selection: scopeBinding) {
      Text("All").tag(GalleryModel.SearchScope.all)
      Text("Filename").tag(GalleryModel.SearchScope.filename)
      Text("Key").tag(GalleryModel.SearchScope.key)
      Text("Note").tag(GalleryModel.SearchScope.note)
    }
    .pickerStyle(.menu)
    .controlSize(.small)
    .fixedSize()
    .labelsHidden()
    .help("Which columns the filter matches")
    .disabled(!appliesHere)
  }

  /// To the right of Scope. Each item carries its count, over all five
  /// sources.
  private var sourcePicker: some View {
    sourceItems
      .pickerStyle(.menu)
      .controlSize(.small)
      .fixedSize()
      .help("Which source the images came from")
      .disabled(!appliesHere)
  }

  /// The popup's items, over the gallery's own `sourceFilter` — the binding
  /// the tests write through to prove this popup and the sort menu's
  /// Show section read one filter.
  var sourceItems: SourceFilterItems {
    SourceFilterItems(source: $model.sourceFilter, counts: model.sourceCounts)
  }

  static func sourceItemTitle(_ title: String, _ count: Int) -> String {
    "\(title) (\(count.formatted()))"
  }

  // MARK: - Inputs

  /// The orphan and usage reloads do not read the search text. The
  /// strip stays typeable (disabling it would resign focus on every report
  /// surface — measured: the focus-survival test went red) and says
  /// out loud, in words, that it does not filter these views; the reload
  /// token separately excludes the search inputs there, so keystrokes on a
  /// report re-run nothing.
  private var appliesHere: Bool {
    switch model.sidebarSelection {
    case .overview, .orphans, .externals, .usage: return false
    default: return true
    }
  }

  private var searchTextBinding: Binding<String> {
    Binding(
      get: { model.searchText },
      set: { model.searchText = $0 }
    )
  }

  private var scopeBinding: Binding<GalleryModel.SearchScope> {
    Binding(
      get: { model.searchScope },
      set: { model.searchScope = $0 }
    )
  }

  private var caseSensitiveBinding: Binding<Bool> {
    Binding(
      get: { model.searchCaseSensitive },
      set: { model.searchCaseSensitive = $0 }
    )
  }

  private var matchModeBinding: Binding<SearchMatch> {
    Binding(
      get: { model.searchMatch },
      set: { model.searchMatch = $0 }
    )
  }
}
