import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// Who Pinax is, the Copy As formats, the download folder, and where the
/// catalog lives. Open at login is not drawn: nothing in the app or
/// CatalogCore sets it.
struct GeneralSettingsPane: View {
  @ObservedObject var preferences: PreferencesStore
  /// Downloads' Choose…: the open panel; tests hand in a folder instead.
  var chooseFolder: (URL) -> URL? = DownloadFolderSection.runOpenPanel

  var body: some View {
    SettingsPage {
      SettingsHeaderCard("Pinax", subtitle: "Version \(appVersion)") {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .frame(width: Metrics.headerIconSize, height: Metrics.headerIconSize)
          .accessibilityHidden(true)
      } trailing: {
        EmptyView()
      }
      CopyFormatsSection(preferences: preferences)
      DownloadFolderSection(preferences: preferences, chooseFolder: chooseFolder)
      SettingsSection("Catalog") {
        SettingsGroup {
          HStack(spacing: Metrics.rowSpacing) {
            Image(systemName: "cylinder")
              .resizable()
              .scaledToFit()
              .frame(width: Metrics.catalogIconSize, height: Metrics.catalogIconSize)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            SettingsRowLabel(
              title: catalogURL.lastPathComponent,
              subtitle: Self.breadcrumb(catalogURL.deletingLastPathComponent()))
              .help(catalogURL.path)
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([catalogURL])
            }
          }
          .padding(.vertical, Metrics.rowVerticalPadding)
          .padding(.horizontal, Metrics.rowHorizontalPadding)
          .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
        }
      }
    }
  }

  /// A folder in words — `Application Support › …` under the user's
  /// Application Support, else the path with `~` for home.
  static func breadcrumb(_ directory: URL) -> String {
    let path = directory.standardizedFileURL.path
    if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?.standardizedFileURL.path, path == support || path.hasPrefix(support + "/")
    {
      let rest = path.dropFirst(support.count).split(separator: "/").map(String.init)
      return (["Application Support"] + rest).joined(separator: " › ")
    }
    return (path as NSString).abbreviatingWithTildeInPath
  }

  /// Pure path computation — no database is opened to display it.
  private var catalogURL: URL { DBLocation.locate() }
  private var appVersion: String {
    let bundle = Bundle.main
    let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (short, build) {
    case let (short?, build?): return "\(short) (\(build))"
    case let (short?, nil): return short
    default: return "—"
    }
  }
}

/// Where Download Original saves. No dialog at download time — the folder
/// is chosen once, here. One menu — the
/// folder, Choose…, and back to Downloads when another one is set.
struct DownloadFolderSection: View {
  enum Choice: Hashable {
    case current, choose, downloads
  }

  @ObservedObject var preferences: PreferencesStore
  let chooseFolder: (URL) -> URL?

  var body: some View {
    SettingsSection("Downloads") {
      SettingsGroup {
        SettingsRow("Save originals to") {
          SettingsMenuPicker("Save originals to", selection: choice) {
            Label {
              Text(folderName)
            } icon: {
              Image(nsImage: folderIcon)
            }
            .tag(Choice.current)
            Divider()
            Text("Choose…").tag(Choice.choose)
            if preferences.downloadFolderPath != nil {
              Text("Use Downloads").tag(Choice.downloads)
            }
          } label: {
            Label {
              Text(folderName)
            } icon: {
              Image(nsImage: folderIcon)
            }
          }
          .help(preferences.downloadFolder.path)
        }
      }
    }
  }

  /// The menu always shows the folder; picking an action runs it.
  var choice: Binding<Choice> {
    Binding(
      get: { .current },
      set: { choice in
        switch choice {
        case .current: break
        case .choose:
          if let url = chooseFolder(preferences.downloadFolder) {
            preferences.downloadFolderPath = url.path
          }
        case .downloads: preferences.downloadFolderPath = nil
        }
      })
  }

  private var folderName: String {
    FileManager.default.displayName(atPath: preferences.downloadFolder.path)
  }

  private var folderIcon: NSImage {
    let icon = NSWorkspace.shared.icon(forFile: preferences.downloadFolder.path)
    icon.size = NSSize(width: Metrics.folderIconSize, height: Metrics.folderIconSize)
    return icon
  }

  static func runOpenPanel(_ start: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = start
    panel.prompt = "Choose"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}

/// The Copy As list — add, edit, remove, and which one is the default. A
/// row per format with its template as code; a
/// click picks a row for −, a double-click opens the sheet that edits it.
/// Unknown placeholders are flagged in that sheet; rendering keeps them as
/// written.
struct CopyFormatsSection: View {
  @ObservedObject var preferences: PreferencesStore
  @State private var selection: UUID?
  @State private var editing: EditedFormat?

  struct EditedFormat: Identifiable {
    let id: UUID
  }

  var body: some View {
    SettingsSection(
      "Copying", note: "The gallery, the drop zone and the menu bar copy links in these formats."
    ) {
      SettingsGroup {
        SettingsRow("Default format") {
          SettingsMenuPicker("Default format", selection: defaultBinding) {
            ForEach(preferences.copyFormats) { format in
              Text(format.name).tag(format.id)
            }
          } label: {
            Text(preferences.defaultCopyFormat?.name ?? "")
          }
          .disabled(preferences.copyFormats.isEmpty)
        }
        ForEach(preferences.copyFormats) { format in
          SettingsRowDivider()
          SettingsRow(format.name) {
            SettingsCodeChip(format.template)
              .frame(maxWidth: Metrics.formatChipMaxWidth, alignment: .trailing)
              .help(format.template)
          }
          .background(selection == format.id ? PinaxPalette.Settings.listSelection : Color.clear)
          .contentShape(Rectangle())
          .gesture(
            TapGesture(count: 2).onEnded { edit(format.id) }
              .exclusively(before: TapGesture().onEnded { selection = format.id }))
          .accessibilityAddTraits(selection == format.id ? [.isSelected, .isButton] : .isButton)
          .accessibilityAction(named: "Edit") { edit(format.id) }
        }
        SettingsRowDivider()
        SettingsAddRemoveBar(
          add: "Add Format", remove: "Remove Format", canRemove: canRemove,
          onAdd: add, onRemove: remove
        ) {
          Text("Double-click a format to edit it")
            .pinaxSettingsRowSubtitle()
        }
      }
    }
    .sheet(item: $editing) { edited in
      if let format = binding(edited.id) {
        CopyFormatSheet(format: format) { editing = nil }
      }
    }
  }

  var canRemove: Bool {
    selection.map { id in preferences.copyFormats.contains { $0.id == id } } ?? false
  }

  func add() {
    let format = CopyFormat(name: "New Format", template: "{url}")
    preferences.copyFormats.append(format)
    edit(format.id)
  }

  func remove() {
    guard let id = selection else { return }
    preferences.copyFormats.removeAll { $0.id == id }
    selection = nil
  }

  private func edit(_ id: UUID) {
    selection = id
    editing = EditedFormat(id: id)
  }

  private func binding(_ id: UUID) -> Binding<CopyFormat>? {
    guard preferences.copyFormats.contains(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { preferences.copyFormats.first { $0.id == id } ?? CopyFormat(name: "", template: "") },
      set: { edited in
        guard let index = preferences.copyFormats.firstIndex(where: { $0.id == id }) else { return }
        preferences.copyFormats[index] = edited
      })
  }

  var defaultBinding: Binding<UUID> {
    Binding(
      get: { preferences.defaultCopyFormat?.id ?? preferences.defaultCopyFormatID },
      set: { preferences.defaultCopyFormatID = $0 })
  }
}

/// One Copy format's name and template, edited in place; the list shows
/// each keystroke as before.
struct CopyFormatSheet: View {
  @Binding var format: CopyFormat
  let done: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.formatSheetSpacing) {
      Text("Edit Format")
        .pinaxSettingsSectionTitle()
      Form {
        TextField("Name", text: $format.name)
        TextField("Template", text: $format.template)
          .pinaxMono()
      }
      let unknown = CopyTemplate.unknownPlaceholders(in: format.template)
      if !unknown.isEmpty {
        Text("Unknown placeholder: " + unknown.joined(separator: " "))
          .foregroundStyle(PinaxPalette.StatusInk.failure)
          .pinaxSettingsRowSubtitle()
      }
      Text("Placeholders: " + CopyTemplate.placeholders.map { "{\($0)}" }.joined(separator: " "))
        .pinaxSettingsRowSubtitle()
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Done", action: done)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Metrics.formatSheetPadding)
    .frame(width: Metrics.sheetWidth)
  }
}
