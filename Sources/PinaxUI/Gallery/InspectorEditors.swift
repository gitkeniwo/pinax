import SwiftUI

// The inspector's tag and note editors. Internal rather than private, so
// the inspector can reach them from its own file.

/// A small inline field for typing a new tag; commits on submit.
struct TagComposer: View {
  /// The inspector's edited field; the composer is `.tag` while typing.
  var focus: FocusState<AssetInspectorView.EditedField?>.Binding
  let onAdd: (String) async -> Void

  @State private var draft = ""

  var body: some View {
    // "+ Add tag…": a 22 pt field, the plus 4 before it.
    HStack(spacing: DesignMetrics.inspectorField.tagIconSpacing) {
      Image(systemName: "plus")
        .pinaxGlyph(DesignMetrics.inspectorField.tagIcon, weight: .semibold)
        .foregroundStyle(.tertiary)
      TextField(
        "Tag",
        text: $draft,
        prompt: Text("Add tag…").foregroundColor(Color(nsColor: .tertiaryLabelColor))
      )
        .textFieldStyle(.plain)
        .pinaxTagField()
        .frame(maxWidth: .infinity)
        .focused(focus, equals: .tag)
        .onExitCommand { focus.wrappedValue = nil }
        .onSubmit {
          let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty else { return }
          draft = ""
          Task {
            await onAdd(name)
          }
        }
    }
    .pinaxFieldChrome(
      focused: focus.wrappedValue == .tag,
      minHeight: DesignMetrics.inspectorField.tagHeight,
      horizontalPadding: DesignMetrics.inspectorField.tagPadding)
    .contentShape(Rectangle())
    .onTapGesture { focus.wrappedValue = .tag }
    .help("Add a tag and press Return")
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > width, x > 0 {
        x = 0
        y += lineHeight + spacing
        lineHeight = 0
      }
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX, x > 0 {
        x = bounds.minX
        y += lineHeight + spacing
        lineHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}
