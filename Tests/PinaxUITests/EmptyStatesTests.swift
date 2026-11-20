import AppKit
@testable import PinaxUI
import SwiftUI
import Testing

/// Every empty state's words come from `EmptyStates.text(for:)`, and this
/// test compares them to the table below row by row — the gate that keeps
/// the final copy final. The symbol is compared too, and each must exist.
@MainActor
@Suite struct EmptyStatesTests {
  /// Kind, symbol, title, description.
  private let table: [(EmptyStateKind, String, String, String?)] = [
    (.noAssets, "photo.on.rectangle.angled", "No Assets",
     "Drop images on the drop zone or press ⌘U to upload."),
    (.emptyFolder, "folder", "Empty Folder", "No assets under this prefix."),
    (.noOrphanCandidates, "checkmark.circle", "No Orphan Candidates",
     "Every active asset was seen in the latest scans."),
    (.usageUnknown(projects: ["astro", "docs"]), "questionmark.circle", "Usage Unknown",
     "Scan astro, docs before reading this list."),
    (.noCompletedScan(project: "astro", hasSources: true), "questionmark.circle",
     "No Completed Scan", "Scan astro's sources to see its references."),
    (.noCompletedScan(project: "astro", hasSources: false), "questionmark.circle",
     "No Completed Scan", "Add a source folder for astro to scan it."),
    (.noReferences, "link", "No References", "The latest completed scan found no references."),
    (.noExternalReferences, "link", "No External References",
     "Every scanned URL matches a catalog asset."),
    (.noBackends, "externaldrive", "No Backends", "Add a backend to start uploading."),
    (.noProjects, "folder.badge.plus", "No Projects", "Create a project to group uploads."),
    (.couldNotOpenCatalog(error: "disk I/O error"), "exclamationmark.triangle",
     "Could Not Open Catalog", "disk I/O error"),
    // The inspector's three, each with a hint line.
    (.noSelection, "photo", "No Selection", "Select an image to see its details."),
    (.nothingToInspect, "chart.bar.xaxis", "Nothing to Inspect", "Overview summarizes the whole project."),
    (.noReferenceSelected, "photo", "No Selection", "Pick a reference to see its link and where it's used."),
  ]

  @Test("Every empty state's title, sentence and symbol match the table, word for word")
  func textIsTheTable() {
    for (kind, symbol, title, description) in table {
      let text = EmptyStates.text(for: kind)
      #expect(text.title == title, "\(kind)")
      #expect(text.description == description, "\(kind)")
      #expect(EmptyStates.symbol(for: kind) == symbol, "\(kind)")
      #expect(
        NSImage(systemSymbolName: symbol, accessibilityDescription: title) != nil,
        "Missing SF Symbol: \(symbol)")
    }
  }

  @Test("No Assets' Upload… reaches the shell's New Upload…")
  func uploadIsWired() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-empty-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    // Not called: it runs the open panel. Its presence is the wiring.
    #expect(gallery.onRequestUpload != nil)
  }

  @Test("An empty asset view fills the centre column; the bars stay at its edges")
  func emptySurfaceFillsTheColumn() async throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-empty-\(UUID().uuidString)"))
    let app = PinaxAppModel(dockIcon: inertDockIcon, defaults: defaults, databaseOpener: { database })
    await app.start()
    let gallery = try #require(app.gallery)
    gallery.select(.archived, in: .library)
    await gallery.reload()
    #expect(gallery.rows.isEmpty && !gallery.isLoadingPage)
    let proposal = CGSize(width: 900, height: 700)
    let size = NSHostingController(rootView: GallerySurface(model: gallery)).sizeThatFits(in: proposal)
    #expect(size == proposal, "\(size)")
  }

  @Test("The inspector's empty state by surface — Overview, Externals, the asset surfaces")
  func inspectorKindBySurface() {
    #expect(EmptyStates.inspectorKind(on: .overview) == .nothingToInspect)
    #expect(EmptyStates.inspectorKind(on: .externals) == .noReferenceSelected)
    for surface: SidebarSelection in [.all, .favorites, .archived, .usage, .orphans] {
      #expect(EmptyStates.inspectorKind(on: surface) == .noSelection, "\(surface)")
    }
  }

  @Test("The empty inspector's sizes — 28 glyph at 0.7, 6 apart, 28 / 52 inset")
  func inspectorEmptyMetrics() {
    let m = DesignMetrics.inspectorEmpty.self
    #expect([m.glyph, m.spacing, m.horizontalPadding, m.bottomPadding] == [28, 6, 28, 52])
    #expect(m.glyphOpacity == 0.7)
  }
}
