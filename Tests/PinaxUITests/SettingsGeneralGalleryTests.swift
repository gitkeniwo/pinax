import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// Settings ▸ General and Gallery, through the panes the Settings window builds:
///
/// - Copy formats and Downloads, on General, read and write their
///   preference keys; Gallery does not carry them.
/// - Gallery's preview is the grid's own cell and follows the preferences.
/// - The source tag cards write the style; the panes' sizes are pinned.
///
/// Views are read as values (Mirror), never opened; no menu, panel or
/// sheet is shown.
@MainActor
@Suite struct SettingsGeneralGalleryTests {
  private func firstView(in value: Any, typePrefix: String) -> Any? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class { return nil }
    if String(describing: type(of: value)).hasPrefix(typePrefix) { return value }
    for child in mirror.children {
      if let found = firstView(in: child.value, typePrefix: typePrefix) { return found }
    }
    return nil
  }

  private func makeStore() throws -> (PreferencesStore, UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-gui7s2-\(UUID().uuidString)"))
    return (PreferencesStore(defaults: defaults), defaults)
  }

  /// The page as the window builds it.
  private func page(
    _ tab: SettingsTab, _ preferences: PreferencesStore, _ defaults: UserDefaults
  ) throws -> (Any, URL) {
    let (database, directory) = try makeUITestDatabase()
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    app.settingsTab = tab
    let settings = PinaxSettingsView(preferences: preferences, app: app)
    let name = tab == .general ? "GeneralSettingsPane" : "GallerySettingsPane"
    return (try #require(firstView(in: settings.body, typePrefix: name)), directory)
  }

  @Test("Copy formats and Downloads on General write their old keys; Gallery has neither")
  func generalCarriesCopyAndDownloads() async throws {
    let (preferences, defaults) = try makeStore()
    let (general, directory) = try page(.general, preferences, defaults)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = try #require(general as? GeneralSettingsPane)

    let copying = try #require(
      firstView(in: pane.body, typePrefix: "CopyFormatsSection") as? CopyFormatsSection)
    let before = preferences.copyFormats.count
    copying.add()
    #expect(preferences.copyFormats.count == before + 1)
    let stored = try #require(defaults.data(forKey: "pinax.copy.formats"))
    let formats = try JSONDecoder().decode([CopyFormat].self, from: stored)
    #expect(formats.last?.name == "New Format" && formats.last?.template == "{url}")

    let second = try #require(preferences.copyFormats.dropFirst().first)
    copying.defaultBinding.wrappedValue = second.id
    #expect(defaults.string(forKey: "pinax.copy.defaultFormat") == second.id.uuidString)

    // Choose… goes through the pane's chooser, here a stub, never a panel.
    let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("pinax-s2-chosen")
    let stubbed = GeneralSettingsPane(preferences: preferences, chooseFolder: { _ in chosen })
    let downloads = try #require(
      firstView(in: stubbed.body, typePrefix: "DownloadFolderSection") as? DownloadFolderSection)
    downloads.choice.wrappedValue = .choose
    #expect(defaults.string(forKey: "pinax.download.folder") == chosen.path)
    downloads.choice.wrappedValue = .downloads
    #expect(defaults.object(forKey: "pinax.download.folder") == nil)

    let (gallery, galleryDirectory) = try page(.gallery, preferences, defaults)
    defer { try? FileManager.default.removeItem(at: galleryDirectory) }
    let galleryBody = try #require(gallery as? GallerySettingsPane).body
    #expect(firstView(in: galleryBody, typePrefix: "CopyFormatsSection") == nil)
    #expect(firstView(in: galleryBody, typePrefix: "DownloadFolderSection") == nil)
  }

  @Test("The catalog's folder reads as Application Support › …")
  func catalogBreadcrumb() throws {
    let support = try #require(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    #expect(
      GeneralSettingsPane.breadcrumb(support.appendingPathComponent("tech.gitkeniwo.pinax"))
        == "Application Support › tech.gitkeniwo.pinax")
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(GeneralSettingsPane.breadcrumb(home.appendingPathComponent("Data")) == "~/Data")
  }

  @Test("The preview is the grid's cell with the preferences' options, and redraws when they change")
  func previewFollowsThePreferences() async throws {
    let (preferences, defaults) = try makeStore()
    let (gallery, directory) = try page(.gallery, preferences, defaults)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = try #require(gallery as? GallerySettingsPane)

    func preview() throws -> GalleryPreview {
      try #require(firstView(in: pane.body, typePrefix: "GalleryPreview") as? GalleryPreview)
    }
    func height() throws -> CGFloat {
      NSHostingView(rootView: try preview()).fittingSize.height
    }
    #expect(try preview().overlays == preferences.gridOverlays)
    #expect(try preview().sizing == preferences.gridThumbnailSizing)
    // The preview is the cell: first in its body, the grid's own view.
    #expect(firstView(in: try preview().body, typePrefix: "AssetGridCell") != nil)

    preferences.gridOverlays.showsFilename = true
    preferences.gridOverlays.sourceTagStyle = .dateLine
    let withFilename = try height()
    preferences.gridOverlays.showsFilename = false
    #expect(try preview().overlays.showsFilename == false)
    let withoutFilename = try height()
    #expect(withoutFilename < withFilename, "\(withoutFilename) vs \(withFilename)")
    // Pill takes the cell's extra row.
    preferences.gridOverlays.sourceTagStyle = .pill
    #expect(try height() > withoutFilename)
    preferences.gridThumbnailSizing = .originalAspect
    #expect(try preview().sizing == .originalAspect)
  }

  @Test("A source tag card writes the style")
  func sourceTagCardsWriteTheStyle() async throws {
    let (preferences, defaults) = try makeStore()
    let (gallery, directory) = try page(.gallery, preferences, defaults)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = try #require(gallery as? GallerySettingsPane)
    let cards = try #require(
      firstView(in: pane.body, typePrefix: "SourceTagCards") as? SourceTagCards)
    cards.selection = .dot
    #expect(preferences.gridOverlays.sourceTagStyle == .dot)
    #expect(defaults.string(forKey: "pinax.grid.sourceTags.style") == "dot")
  }

  @Test("The panes' sizes")
  func s2Configuration() {
    typealias m = DesignMetrics.settings
    #expect(m.previewCellWidth == 132)
    #expect(m.previewPadding == 16)
    #expect(m.sourceCardSampleHeight == 46 && m.sourceCardRadius == 8)
    #expect(m.sourceCardSpacing == 8 && m.sourceCardsPadding == 12)
    #expect(m.formatChipMaxWidth == 250)
    #expect(m.catalogIconSize == 22)
  }
}
