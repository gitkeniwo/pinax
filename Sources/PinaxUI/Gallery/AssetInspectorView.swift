import AppKit
import CatalogCore
import SwiftUI

/// One stable root: the `ScrollView` below is present in every
/// state, and so are the sections inside it. The old shape —
/// `Group { if let details ScrollView else Text }` — destroyed the whole
/// subtree whenever `selectedDetails` crossed nil, which happens on real
/// transitions (grid → orphans clears `rows` before the report lands), and a
/// destroyed subtree is what "inspector flicker" actually was. The fix is
/// identity, not animation: sections are structural, data
/// is optional.
///
/// Flat groups split by dividers, the way Photos' ⌘I
/// panel and Finder's Get Info are — preview, title block, Link, Note, Tags,
/// Projects, Identity. With nothing selected the column shows only "No
/// Selection"; the sections stay mounted underneath it, hidden and
/// taking no height, so the next selection fills them in instead of building
/// them. Live usage is per-asset and framed as a lower bound — `0 live`
/// never reads as proof an asset is unused.
struct AssetInspectorView: View {
  @ObservedObject var model: GalleryModel

  /// Identity instrument, exercised by the hosted stability test: it
  /// renders as the background of the Identity group's first row — the
  /// deepest always-present spot in the stable root — and must appear exactly
  /// once per hosting no matter how the selection (or its absence) changes.
  /// The test ships a falsifier twin of the old branch-swap shape proving
  /// this counter would re-fire if the identity broke again.
  var identityProbe: (() -> Void)? = nil

  /// Tests observe a real root-level `@State` value across window resizes:
  /// the docked inspector keeps its identity at every width.
  var presentationIdentityProbe: ((UUID) -> Void)? = nil
  /// The gallery's docked column: the translucent sidebar material, like the
  /// navigation sidebar opposite. Off for standalone hosting.
  var usesMaterialBackground = false
  /// Where the Link group's copy button writes; tests pass a private board.
  var pasteboard: NSPasteboard = .general
  /// Where the link row's Open in Browser sends the public URL; tests
  /// record it instead.
  var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

  @State private var pendingUnlink: PendingUnlink?
  @State private var presentationIdentity = UUID()
  /// The text field being edited. Escape, a click on the column's empty
  /// space or a new selection ends the edit, so a note never keeps its
  /// focus with no way out.
  @FocusState private var focusedField: EditedField?

  enum EditedField: Hashable {
    case note, tag
  }

  struct PendingUnlink: Identifiable {
    let id = UUID()
    let slug: String
    let name: String
    let liveCount: Int
  }

  private var details: CatalogAssetDetails? { model.selectedDetails }
  /// Two or more rows selected. `details` is nil then (the single
  /// path is driven by `selectedID`), so Link, Note and Identity read "—".
  private var multiCount: Int? {
    model.selectedIDs.count > 1 ? model.selectedIDs.count : nil
  }
  private var editable: Bool { model.editor != nil }
  /// Nothing to show — the column is "No Selection" alone. Also on
  /// the surfaces that list references, not assets.
  private var showsNoSelection: Bool {
    !model.showsAssetSelection || (details == nil && multiCount == nil)
  }

  var body: some View {
    ScrollView {
      ZStack(alignment: .top) {
        sections
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(DesignMetrics.inspector.padding)
          // Hidden, not removed: the sections keep their identity through
          // the empty state (the stable root).
          .frame(height: showsNoSelection ? 0 : nil, alignment: .top)
          .opacity(showsNoSelection ? 0 : 1)
          .allowsHitTesting(!showsNoSelection)
          .accessibilityHidden(showsNoSelection)
        if model.shownSelection == .externals {
          // A reference, not an asset — its own sections.
          ExternalInspector(model: model.externals)
        } else if showsNoSelection {
          InspectorEmptyState(kind: EmptyStates.inspectorKind(on: model.shownSelection))
            .containerRelativeFrame(.vertical)
        }
      }
      // The inspector column animates through proposals much narrower
      // than its final width. Keep the content's reported width bounded by
      // that final column and clip it during the transition, or its intrinsic
      // minimum can over-constrain the split view and push the sidebar left.
      .frame(width: GalleryWidthBudget.inspectorWidth, alignment: .leading)
      .clipped()
    }
    .scrollIndicators(.hidden)
    .background {
      if usesMaterialBackground {
        SidebarMaterialBackground()
      } else {
        Color(nsColor: .controlBackgroundColor)
      }
    }
    .background(
      Color.clear.onAppear {
        presentationIdentityProbe?(presentationIdentity)
      }
    )
    .confirmationDialog(
      "Remove “\(pendingUnlink?.name ?? "")”?",
      isPresented: Binding(
        get: { pendingUnlink != nil },
        set: { if !$0 { pendingUnlink = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(
        "Remove anyway — the image will disappear from this project's manifest",
        role: .destructive
      ) {
        guard let slug = pendingUnlink?.slug else { return }
        Task {
          await model.setProjectMembership(false, slug: slug, confirmedUnlink: true)
        }
        pendingUnlink = nil
      }
      Button("Cancel", role: .cancel) { pendingUnlink = nil }
    } message: {
      Text(
        "The site still references this image \(pendingUnlink?.liveCount ?? 0)× in "
          + "\(pendingUnlink?.name ?? ""). Removing membership hides it from this "
          + "project's export immediately, and re-scanning will not restore it."
      )
    }
    .confirmationDialog(
      model.pendingSelectionUnlink?.title ?? "",
      isPresented: Binding(
        get: { model.pendingSelectionUnlink != nil },
        set: { if !$0 { model.cancelSelectionUnlink() } }
      ),
      titleVisibility: .visible,
      presenting: model.pendingSelectionUnlink
    ) { pending in
      Button(pending.confirmLabel, role: .destructive) {
        Task { await model.confirmSelectionUnlink(pending) }
      }
      Button("Cancel", role: .cancel) { model.cancelSelectionUnlink() }
    } message: { pending in
      Text(pending.message)
    }
  }

  // MARK: - Sections (top to bottom)

  /// The collapsible bands, in display order; each
  /// remembers per window whether it is open. Identity starts closed, as
  /// its disclosure group did.
  enum Band: String, CaseIterable {
    case sourceLink, note, tagsLabels, projects, usedIn, identity

    var title: String {
      switch self {
      case .sourceLink: return "Source & Link"
      case .note: return "Note"
      case .tagsLabels: return "Tags & Labels"
      case .projects: return "Projects"
      case .usedIn: return "Used In"
      case .identity: return "Identity"
      }
    }

    var storageKey: String { "pinax.inspector.band.\(rawValue)" }
    var expandedByDefault: Bool { self != .identity }
  }

  /// The bands top to bottom: Usage leads with Used In;
  /// every other page keeps the standard order.
  static func bandOrder(on surface: SidebarSelection) -> [Band] {
    let rest: [Band] = [.sourceLink, .note, .tagsLabels, .projects, .identity]
    return surface == .usage ? [.usedIn] + rest : [.sourceLink, .note, .tagsLabels, .projects, .usedIn, .identity]
  }

  private var sections: some View {
    // Usage leads with Used In; every other page keeps the
    // standard order. The first band reads `bandOrder`, which the
    // tests pin.
    let leadsWithUsedIn = Self.bandOrder(on: model.shownSelection).first == .usedIn
    return VStack(alignment: .leading, spacing: DesignMetrics.inspector.bandSpacing) {
      preview
      if let details {
        statPills(details)
      }
      if leadsWithUsedIn { usedInBand }
      band(.sourceLink) { sourceLinkFields }
      band(.note) { noteField }
      band(.tagsLabels) { tagsLabelsFields }
      band(.projects) { projectsRows }
      if !leadsWithUsedIn { usedInBand }
      identityGroup
    }
    // A click on the column's empty space ends an edit; the controls above
    // keep their own clicks.
    .background {
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
    }
    .onChange(of: model.selectedIDs) { focusedField = nil }
  }

  /// Usage shows the file over "project › directory" and the line's
  /// capsule; the library keeps its one-line rows.
  private var usedInBand: some View {
    band(.usedIn, count: usedInCount) {
      UsedInGroup(
        state: model.usedIn, isMultiple: multiCount != nil, inBand: true,
        showsReferenceDetail: model.shownSelection == .usage
      ) { [model] in
        guard let id = model.selectedID else { return }
        Task { await model.showAllUsage(of: id) }
      }
    }
  }

  /// The Used In band's trailing figure (the reference
  /// count) once there is a single selection that something references.
  var usedInCount: String? {
    guard multiCount == nil, case let .used(_, total, _) = model.usedIn else { return nil }
    return total.formatted()
  }

  private func band<Content: View>(
    _ band: Band, count: String? = nil, @ViewBuilder content: () -> Content
  ) -> some View {
    InspectorBandSection(
      band.title, storageKey: band.storageKey, expandedByDefault: band.expandedByDefault,
      count: count, content: content)
  }

  /// An empty field once something is selected.
  private func placeholder(_ text: String = "—") -> some View {
    Text(text)
      .pinaxFieldValue()
      .foregroundStyle(.tertiary)
  }

  /// The column inside the inspector's padding.
  static var columnWidth: CGFloat {
    GalleryWidthBudget.inspectorWidth - 2 * DesignMetrics.inspector.padding
  }

  // MARK: - 0. Title

  /// What the title names: the file over "date · kind". It is drawn in the
  /// column's strip under the toolbar (`InspectorTitleBar`), beside the
  /// toolbar's own inspector toggle.
  static func headerTitle(_ details: CatalogAssetDetails) -> (title: String, subtitle: String) {
    let asset = details.item.asset
    return (
      asset.originalFilename ?? "—",
      [PinaxFormat.date(asset.uploadedAt, style: .dayTime), PinaxFormat.kind(mime: asset.mime)]
        .joined(separator: " · ")
    )
  }

  // MARK: - 1. Preview

  /// The one rounded container in this file: the thumbnail's.
  @ViewBuilder
  private var preview: some View {
    if let multiCount {
      Text("\(multiCount) items selected")
        .pinaxTitle()
        .monospacedDigit()
        .frame(maxWidth: .infinity)
    } else if let details {
      let shape = RoundedRectangle(cornerRadius: DesignMetrics.inspector.previewRadius, style: .continuous)
      ThumbnailView(item: details.item, cache: model.thumbnails, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(height: Self.previewHeight(width: details.item.asset.width, height: details.item.asset.height))
        .background(.quaternary, in: shape)
        .clipShape(shape)
    }
  }

  /// The asset's own aspect across the column's width, at least
  /// `previewMinHeight` and at most `previewMaxHeight`; an asset without
  /// dimensions gets the cap. Computed from constants, so the preview never
  /// negotiates its size.
  static func previewHeight(width: Int?, height: Int?) -> CGFloat {
    let maxHeight = DesignMetrics.inspector.previewMaxHeight
    guard let width, let height, width > 0, height > 0 else {
      return maxHeight
    }
    let aspect = columnWidth * CGFloat(height) / CGFloat(width)
    return min(maxHeight, max(DesignMetrics.inspector.previewMinHeight, aspect))
  }

  // MARK: - 2. Stat pills

  /// The size pill and the dimensions pill share the column 1 : 1.35.
  static var statPillWidths: (size: CGFloat, dimensions: CGFloat) {
    let share = DesignMetrics.inspectorStats.dimensionsShare
    let unit = (columnWidth - DesignMetrics.inspectorStats.spacing) / (1 + share)
    return (unit, unit * share)
  }

  private func statPills(_ details: CatalogAssetDetails) -> some View {
    let asset = details.item.asset
    let widths = Self.statPillWidths
    return HStack(spacing: DesignMetrics.inspectorStats.spacing) {
      StatPill.size(PinaxFormat.fileSize(asset.byteSize))
        .frame(width: widths.size)
        .help("File size")
      StatPill.dimensions(PinaxFormat.dimensions(width: asset.width, height: asset.height) ?? "—")
        .frame(width: widths.dimensions)
        .help("Dimensions")
    }
  }

  // MARK: - 3. Source & Link

  /// Where the image came from, as `AssetSourceDescription` words it, with
  /// the entry date in `PinaxFormat`.
  static func sourceText(_ details: CatalogAssetDetails) -> String {
    AssetSourceDescription(asset: details.item.asset, backend: details.item.backend)
      .text(date: PinaxFormat.date(details.item.asset.createdAt, style: .day))
  }

  /// A migrated asset's original link, which its Source row opens.
  static func sourceOriginalURL(_ details: CatalogAssetDetails) -> URL? {
    AssetSourceDescription(asset: details.item.asset, backend: details.item.backend).originalURL
  }

  /// The source's square colour: the grid's (`SourceTint.token`); Pinax's
  /// own uploads, unmarked in the grid, are gray.
  static func sourceToken(_ source: AssetSource) -> PinaxPalette.Token {
    SourceCaption.tint(of: source)?.token ?? .gray
  }

  /// The link's two lines: its file name, then "host › directory › …".
  static func linkParts(_ link: String) -> (name: String, location: String) {
    guard let url = URL(string: link), let host = url.host, !host.isEmpty else {
      return (link, "")
    }
    let components = url.pathComponents.filter { $0 != "/" }
    guard let name = components.last else { return (host, "") }
    return (name, ([host] + components.dropLast()).joined(separator: " › "))
  }

  private var sourceLinkFields: some View {
    InspectorFieldGrid {
      InspectorFieldRow("Source") {
        if let details {
          let text = Self.sourceText(details)
          let original = Self.sourceOriginalURL(details)
          HStack(spacing: DesignMetrics.inspectorFields.sourceSpacing) {
            ColorSquare(
              size: .caption,
              color: PinaxPalette.color(Self.sourceToken(AssetSource.of(meta: details.item.asset.meta))),
              content: .letters(""))
            if let original {
              // Migrated from <host> opens the
              // image where it was copied from.
              Button {
                NSWorkspace.shared.open(original)
              } label: {
                Text(text)
                  .pinaxFieldValue()
                  .lineLimit(2)
              }
              .buttonStyle(.plain)
              .help(original.absoluteString)
            } else {
              Text(text)
                .pinaxFieldValue()
                .lineLimit(2)
                .help(text)
            }
          }
        } else {
          placeholder()
        }
      }
      InspectorFieldRow("Link") {
        if let url = details?.item.url {
          let parts = Self.linkParts(url)
          // Not selectable: a selectable Text drops its truncation. The copy button and ⌘C carry the link instead.
          VStack(alignment: .leading, spacing: DesignMetrics.inspectorFields.linkLineSpacing) {
            Text(parts.name)
              .pinaxLinkName()
              .lineLimit(1)
              .truncationMode(.middle)
            Text(parts.location)
              .pinaxLinkPath()
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .help(url)
        } else {
          placeholder()
        }
      }
      if details?.item.url != nil {
        InspectorFieldRow(nil) { linkActions }
      }
    }
  }

  /// The link row's buttons, left to right after the format pop-up.
  enum LinkAction: String, CaseIterable, Identifiable {
    case copy, download, openInBrowser

    var id: String { rawValue }

    var title: String {
      switch self {
      case .copy: return "Copy Link"
      case .download: return "Download Original"
      case .openInBrowser: return "Open in Browser"
      }
    }

    var systemImage: String {
      switch self {
      case .copy: return "doc.on.doc"
      case .download: return "arrow.down.to.line"
      case .openInBrowser: return "arrow.up.right.square"
      }
    }
  }

  /// The selected asset's public URL, as Open in Browser opens it.
  var browserURL: URL? {
    details.flatMap { URL(string: $0.item.url) }
  }

  func isEnabled(_ action: LinkAction) -> Bool {
    switch action {
    case .copy: return copyButtonFormat != nil
    case .download: return model.canDownloadSelection
    case .openInBrowser: return browserURL != nil
    }
  }

  /// A link button's click. Copy is ⌘C's own call; Download is File ▸
  /// Download Original's (`OriginalDownloader` through the gallery); Open
  /// hands the public URL to the default browser.
  func perform(_ action: LinkAction) async {
    switch action {
    case .copy: copyInDefaultFormat()
    case .download: await model.downloadSelection()
    case .openInBrowser:
      if let browserURL { openURL(browserURL) }
    }
  }

  private var linkActions: some View {
    HStack(spacing: DesignMetrics.iconButton.spacing) {
      formatMenu
      Spacer(minLength: 0)
      ForEach(LinkAction.allCases) { action in
        Button {
          Task { await perform(action) }
        } label: {
          Label(action.title, systemImage: action.systemImage)
        }
        .buttonStyle(.pinaxIcon)
        .disabled(!isEnabled(action))
        .help(action == .copy ? "Copy as \(copyButtonFormat?.name ?? "") (⌘C)" : action.title)
      }
    }
  }

  /// The format ⌘C writes, by name; its items copy in Copy As's
  /// other formats, as the old split button's arrow did.
  @ViewBuilder
  private var formatMenu: some View {
    if let format = copyButtonFormat {
      Menu {
        ForEach(model.copyFormats.filter { $0.id != format.id }) { other in
          Button(other.name) { copy(as: other) }
        }
      } label: {
        PinaxPopupLabel(format.name)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Copy As")
    }
  }

  /// The format the copy button and the pop-up are named after: ⌘C's.
  var copyButtonFormat: CopyFormat? {
    model.defaultCopyFormat ?? model.copyFormats.first
  }

  /// The copy button's click.
  func copyInDefaultFormat() {
    model.copySelectionInDefaultFormat(to: pasteboard)
  }

  /// One of the pop-up's items.
  func copy(as format: CopyFormat) {
    model.copySelection(as: format, to: pasteboard)
  }

  // MARK: - 6. Note

  private var noteField: some View {
    let note = details?.item.asset.note
    return VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
      if editable, details != nil {
        TextField(
          "Note",
          text: $model.noteDraft,
          prompt: Text("Add a note…").foregroundColor(Color(nsColor: .tertiaryLabelColor)),
          axis: .vertical
        )
          .textFieldStyle(.plain)
          .pinaxFieldValue()
          .focused($focusedField, equals: .note)
          .onExitCommand { focusedField = nil }
          .pinaxFieldChrome(
            focused: focusedField == .note,
            minHeight: DesignMetrics.inspectorField.noteHeight,
            horizontalPadding: DesignMetrics.inspectorField.notePadding,
            verticalPadding: DesignMetrics.inspectorField.noteVerticalPadding)
          .onSubmit { Task { await model.saveNote() } }
          .disabled(model.isSavingEdit)
        if model.isSavingEdit {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if model.noteDraft != (note ?? "") {
          Button("Save") { Task { await model.saveNote() } }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      } else if let note {
        Text(note)
          .pinaxFieldValue()
          .textSelection(.enabled)
      } else {
        placeholder(details == nil ? "—" : "No note")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - 8. Tags & Labels

  private var tagsLabelsFields: some View {
    InspectorFieldGrid {
      InspectorFieldRow("Tags") { tagsValue }
      InspectorFieldRow("Labels") { labelsValue }
    }
  }

  @ViewBuilder
  private var tagsValue: some View {
    if let details {
      if details.tags.isEmpty && !editable {
        placeholder("No tags")
      } else {
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
          if !details.tags.isEmpty {
            FlowLayout(spacing: DesignMetrics.spacing.xs) {
              ForEach(details.tags, id: \.self) { tag in
                HStack(spacing: DesignMetrics.spacing.xs) {
                  Text(tag)
                    .pinaxCaption()
                  if editable {
                    Button {
                      Task { await model.removeTag(tag) }
                    } label: {
                      Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove tag “\(tag)”")
                    .disabled(model.isSavingEdit)
                  }
                }
                .metadataChipStyle()
              }
            }
          }
          if editable {
            TagComposer(focus: $focusedField) { name in
              await model.addTag(name)
            }
            .disabled(model.isSavingEdit)
          }
        }
      }
    } else if multiCount != nil, editable {
      TagComposer(focus: $focusedField) { name in
        await model.addTagToSelection(name)
      }
      .disabled(model.isSavingEdit)
    } else {
      placeholder()
    }
  }

  /// Favourite and Finder's seven labels, over the whole
  /// selection, as one band.
  @ViewBuilder
  private var labelsValue: some View {
    if editable, let target = model.selectionTargetIfAny {
      let favorite = model.favoriteState(of: target) == true
      HStack(spacing: DesignMetrics.labelBand.spacing) {
        Button {
          Task { await model.toggleFavorite(target) }
        } label: {
          Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.fill" : "heart")
            .labelStyle(.iconOnly)
            .pinaxGlyph(DesignMetrics.labelBand.heart)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(favorite ? "Unfavorite" : "Favorite")
        labelBand(for: target)
      }
      .disabled(model.isSavingEdit)
    } else {
      placeholder()
    }
  }

  /// The band for a selection: each label's state over it, and a click
  /// that toggles that label over it — the old dots' call.
  func labelBand(for target: GalleryModel.ContextMenuTarget) -> LabelBand {
    LabelBand(
      states: Dictionary(
        uniqueKeysWithValues: AssetLabel.allCases.map { ($0, model.labelState($0, of: target)) })
    ) { [model] label in
      Task { await model.toggleLabel(label, for: target) }
    }
  }

  // MARK: - 10. Projects

  /// A project's letter on its square ("astro" reads "A").
  static func projectLetter(_ name: String) -> String {
    name.first.map { String($0).uppercased() } ?? "—"
  }

  /// Membership and per-asset live counts share one band. The counts come
  /// only from `details.projects`; `model.projects` carries project-wide
  /// usage, which is exactly the bug `d27b939` fixed and must not return.
  private var projectsRows: some View {
    let memberSlugs = Set(details?.projects.map(\.slug) ?? [])
    let liveForThisAsset = Dictionary(
      uniqueKeysWithValues: (details?.projects ?? []).map { ($0.slug, $0.liveUsageCount) })
    return VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
      if model.projects.isEmpty {
        if let projects = details?.projects, !projects.isEmpty {
          ForEach(projects, id: \.slug) { project in
            projectRow(project.name) {
              liveCount(project.liveUsageCount)
              membershipMark(true)
            }
          }
        } else {
          placeholder(details == nil ? "—" : "Not in any project")
        }
      } else {
        ForEach(model.projects, id: \.slug) { project in
          let live = liveForThisAsset[project.slug] ?? 0
          projectRow(project.name) {
            if multiCount != nil {
              // Mixed membership reads "—"; per-asset live counts do not
              // add up across a selection, so none is shown.
              Text(model.selectionMembership(ofProject: project.slug) == nil ? "—" : "")
                .pinaxSecondary()
                .foregroundStyle(.tertiary)
            } else {
              liveCount(live)
            }
            if editable, multiCount != nil {
              membershipSwitch(project.name, isOn: Binding(
                get: { switchIsOn(project.slug) },
                set: { member in
                  Task { await model.setProjectMembershipForSelection(member, slug: project.slug) }
                }
              ))
            } else if editable, details != nil {
              membershipSwitch(project.name, isOn: Binding(
                get: { switchIsOn(project.slug) },
                set: { member in
                  if !member, live > 0 {
                    pendingUnlink = PendingUnlink(
                      slug: project.slug,
                      name: project.name,
                      liveCount: live
                    )
                  } else {
                    Task { await model.setProjectMembership(member, slug: project.slug) }
                  }
                }
              ))
            } else {
              membershipMark(memberSlugs.contains(project.slug))
            }
          }
        }
      }
      Text("Live usage is a lower bound found by scanning; 0 means “none seen”, not “none exist”.")
        .pinaxFootnote()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, DesignMetrics.inspectorProjects.footnoteSpacing)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func projectRow<Trailing: View>(
    _ name: String, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: DesignMetrics.inspectorProjects.spacing) {
      ColorSquare(
        size: .folder, color: SidebarIconTint.project.color,
        content: .letters(Self.projectLetter(name)))
      Text(name)
        .pinaxRowTitle()
        .lineLimit(1)
      Spacer(minLength: 0)
      trailing()
    }
  }

  /// What a project's switch shows: on when the asset — or every selected
  /// asset — is in the project; a mixed selection reads off.
  func switchIsOn(_ slug: String) -> Bool {
    if multiCount != nil { return model.selectionMembership(ofProject: slug) == true }
    return details?.projects.contains { $0.slug == slug } ?? false
  }

  private func membershipSwitch(_ name: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      Text(name)
    }
    .labelsHidden()
    .toggleStyle(.pinaxMembership)
    .disabled(model.isSavingEdit)
  }

  private func liveCount(_ count: Int) -> some View {
    HStack(spacing: DesignMetrics.inspectorProjects.liveSpacing) {
      Circle()
        .fill(count > 0 ? AnyShapeStyle(PinaxPalette.liveDot) : AnyShapeStyle(.tertiary))
        .frame(width: DesignMetrics.inspectorProjects.liveDot, height: DesignMetrics.inspectorProjects.liveDot)
      Text("\(count) live")
        .pinaxSecondary()
        .monospacedDigit()
    }
    .help("Live usage is a lower bound and never authorizes destructive action")
  }

  private func membershipMark(_ member: Bool) -> some View {
    Image(systemName: member ? "checkmark.circle.fill" : "circle")
      .imageScale(.small)
      .foregroundStyle(member ? AnyShapeStyle(PinaxPalette.accent) : AnyShapeStyle(.secondary))
  }

  // MARK: - 12. Identity

  private var identityGroup: some View {
    let asset = details?.item.asset
    return band(.identity) {
      VStack(alignment: .leading, spacing: DesignMetrics.inspector.rowSpacing) {
        fieldRow("Key") {
          if let key = asset?.key {
            Text(key)
              .pinaxMono()
              .textSelection(.enabled)
          } else {
            placeholder()
          }
        }
        fieldRow("SHA-256") {
          if let sha = asset?.sha256 {
            HStack(alignment: .firstTextBaseline) {
              Text(sha)
                .pinaxMono()
                .lineLimit(2)
                .truncationMode(.middle)
              Spacer(minLength: 0)
              Button {
                PasteboardWriter.copy(sha)
              } label: {
                Label("Copy SHA-256", systemImage: "doc.on.doc")
                  .labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
              .help("Copy SHA-256")
            }
          } else {
            placeholder()
          }
        }
      }
    }
    .background(
      Group {
        if let identityProbe {
          Color.clear.onAppear { identityProbe() }
        }
      }
    )
  }

  /// A label over its value; an absent value is the placeholder dash, so
  /// the row keeps its shape loaded and unloaded.
  private func fieldRow<Value: View>(
    _ title: String, @ViewBuilder value: () -> Value
  ) -> some View {
    InspectorField(title, value: value)
  }
}
