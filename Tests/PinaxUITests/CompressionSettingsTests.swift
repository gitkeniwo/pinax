import AppKit
@testable import CatalogCore
import Foundation
import GRDB
@testable import PinaxUI
import SwiftUI
import Testing

/// A project's Compression section in Settings ▸ Projects, and the Compress
/// images box on the external-image migration's confirmation sheet. The
/// settings run on an in-memory store; the migration core is stubbed.
@MainActor
@Suite struct CompressionSettingsTests {
  /// The settings writes as the model makes them, kept in memory.
  final class MemoryStore: ProjectSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [ProjectSettingsRow]
    private(set) var writes: [ProjectCompression] = []

    init(compression: ProjectCompression = ProjectCompression()) {
      rows = [
        ProjectSettingsRow(id: 1, slug: "astro", name: "astro", keyPrefix: "", backendSlug: "r2", compression: compression)
      ]
    }

    func snapshot() throws -> ProjectSettingsSnapshot {
      lock.withLock { ProjectSettingsSnapshot(rows: rows, backendSlugs: ["r2"]) }
    }

    func setCompression(_ compression: ProjectCompression, projectSlug: String) throws {
      lock.withLock {
        writes.append(compression)
        rows = rows.map { row in
          guard row.slug == projectSlug else { return row }
          return ProjectSettingsRow(
            id: row.id, slug: row.slug, name: row.name, keyPrefix: row.keyPrefix, backendSlug: row.backendSlug,
            compression: compression)
        }
      }
    }

    func setKeyPrefix(_ keyPrefix: String, projectSlug: String) throws {}
    func setKeyTemplate(_ change: KeyTemplateChange, projectSlug: String) throws {}
    func setBackend(slug: String?, projectSlug: String) throws {}
    func setSources(_ sources: [ProjectSource], projectSlug: String) throws {}
    func setUsageTracking(_ tracking: UsageTracking, projectSlug: String) throws {}
    func setAutoScan(_ autoScan: ProjectAutoScan, projectSlug: String) throws {}
    func addProject(_ draft: NewProjectDraft) async throws -> ProjectSettingsSnapshot { try snapshot() }
  }

  private func section(_ store: MemoryStore) throws -> (ProjectSettingsModel, () throws -> ProjectCompressionSection) {
    let model = ProjectSettingsModel(store: store, chooseFolder: { _ in nil })
    model.load()
    return (
      model,
      {
        let row = try #require(model.snapshot?.rows.first)
        return ProjectCompressionSection(row: row, model: model)
      }
    )
  }

  /// Each titled control under `view` with whether the `.disabled`
  /// modifiers above it leave it enabled (the Drop Zone page's walk).
  private func controlStates(in view: Any, enabled: Bool = true) -> [String: Bool] {
    let name = String(describing: type(of: view))
    if let row = view as? SettingsRowSwitch { return ["switch " + row.title: enabled] }
    if let slider = view as? SettingsQualitySlider { return ["slider " + slider.title: enabled] }
    if name.hasPrefix("SettingsMenuPicker") {
      let title = Mirror(reflecting: view).children.first { $0.label == "title" }?.value as? String
      return ["menu " + (title ?? "?"): enabled]
    }
    let mirror = Mirror(reflecting: view)
    if mirror.displayStyle == .class { return [:] }
    if name.hasPrefix("ModifiedContent") {
      var content: Any?
      var modifier: Any?
      for child in mirror.children {
        if child.label == "content" { content = child.value }
        if child.label == "modifier" { modifier = child.value }
      }
      var inner = enabled
      if let modifier, String(describing: type(of: modifier)).hasPrefix("_EnvironmentKeyTransformModifier<Bool>"),
        let transform = Mirror(reflecting: modifier).children.first(where: { $0.label == "transform" })?.value
          as? (inout Bool) -> Void
      {
        transform(&inner)
      }
      return content.map { controlStates(in: $0, enabled: inner) } ?? [:]
    }
    return mirror.children.reduce(into: [:]) { result, child in
      result.merge(controlStates(in: child.value, enabled: enabled)) { first, _ in first }
    }
  }

  // MARK: - Settings ▸ Projects

  @Test("A project with nothing stored shows compression off, 2048 px, 85%, metadata removed")
  func defaults() throws {
    let (_, make) = try section(MemoryStore())
    let section = try make()
    #expect(!section.isEnabled.wrappedValue)
    #expect(section.longestEdge.wrappedValue == 2048)
    #expect(section.quality.wrappedValue == 85)
    #expect(section.removesMetadata.wrappedValue)
    #expect(ProjectCompressionSection.longestEdgeLabel(2048) == "2048 px")
    #expect(ProjectCompressionSection.longestEdgeLabel(nil) == "Don't resize")
    #expect(ProjectCompressionSection.longestEdges == [1600, 2048, 2560, 3840])
    #expect(([85, 75, 60, 100] as [CompressionQuality]).map(ProjectCompressionSection.qualityLabel) == ["85%", "75%", "60%", "100%"])
    #expect(ProjectCompressionSection.metadataNote == "Includes location.")
  }

  @Test("With the switch off the three rows below it are disabled; on, all four are enabled")
  func disabling() throws {
    let store = MemoryStore()
    let (_, make) = try section(store)
    let off = controlStates(in: try make().body)
    #expect(
      off == [
        "switch Compress on upload": true, "menu Longest edge": false, "slider Quality": false,
        "switch Remove metadata": false,
      ], "\(off)")

    try make().isEnabled.wrappedValue = true
    let on = controlStates(in: try make().body)
    #expect(on.count == 4 && on.values.allSatisfy { $0 }, "\(on)")
  }

  @Test("Each control writes at once, keeping the other stored values")
  func writes() throws {
    let store = MemoryStore()
    let (model, make) = try section(store)
    try make().isEnabled.wrappedValue = true
    try make().longestEdge.wrappedValue = nil
    try make().quality.wrappedValue = 60
    try make().removesMetadata.wrappedValue = false
    let expected = ProjectCompression(
      isEnabled: true, options: CompressionOptions(longestEdge: nil, quality: 60, removesMetadata: false))
    #expect(store.writes.count == 4)
    #expect(store.writes.last == expected)
    #expect(store.writes.first == ProjectCompression(isEnabled: true))
    #expect(model.snapshot?.rows.first?.compression == expected)
    // Off keeps the values for next time.
    try make().isEnabled.wrappedValue = false
    #expect(store.writes.last?.options == expected.options)
  }

  @Test("The quality slider spans 40 to 100, ticks the old steps and rounds to a whole percent")
  func qualitySlider() throws {
    #expect(SettingsQualitySlider.bounds == 40...100)
    #expect(SettingsQualitySlider.quality(forSliderValue: 72.4) == 72)
    #expect(SettingsQualitySlider.quality(forSliderValue: 72.6) == 73)
    #expect(SettingsQualitySlider.quality(forSliderValue: 12) == 40)
    let width = DesignMetrics.settings.qualitySliderWidth
    let inset = DesignMetrics.settings.qualityTickInset
    #expect(SettingsQualitySlider.tickOffset(40, width: width) == inset)
    #expect(SettingsQualitySlider.tickOffset(100, width: width) == width - inset)
    let offsets = CompressionQuality.ticks.map { SettingsQualitySlider.tickOffset($0, width: width) }
    #expect(offsets == offsets.sorted() && Set(offsets).count == 3)

    // The row's slider writes through the section's binding.
    let store = MemoryStore(compression: ProjectCompression(isEnabled: true))
    let (_, make) = try section(store)
    try make().quality.wrappedValue = 72
    #expect(store.writes.last?.options.quality == 72)
    #expect(try make().quality.wrappedValue == 72)
  }

  @Test("A longest edge set elsewhere is offered and marked in the menu")
  func customEdge() throws {
    var options = CompressionOptions.default
    options.longestEdge = 1000
    let (_, make) = try section(MemoryStore(compression: ProjectCompression(isEnabled: true, options: options)))
    #expect(try make().edgeChoices == [1000, 1600, 2048, 2560, 3840])
    let (_, standard) = try section(MemoryStore())
    #expect(try standard().edgeChoices == ProjectCompressionSection.longestEdges)
  }

  @Test("The catalog store writes the choice into project.meta and reads it back")
  func catalogRoundTrip() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ProjectSettingsModel(store: CatalogProjectSettingsStore(database: database), chooseFolder: { _ in nil })
    model.load()
    #expect(model.snapshot?.rows.first { $0.slug == "blog" }?.compression == ProjectCompression())
    model.setCompression(forProject: "blog") {
      $0.isEnabled = true
      $0.options.quality = 75
    }
    #expect(model.saveError == nil)
    let stored = try CatalogConfiguration.projectSettings(slug: "blog", in: database).compression
    #expect(stored == ProjectCompression(isEnabled: true, options: CompressionOptions(longestEdge: 2048, quality: 75, removesMetadata: true)))
    #expect(model.snapshot?.rows.first { $0.slug == "blog" }?.compression == stored)
    #expect(try CatalogConfiguration.projectSettings(slug: "notes", in: database).compression == ProjectCompression())
  }

  // MARK: - The migration sheet

  private struct Rows: ExternalUsageReading {
    func externalReferences(project: String?) async throws -> ExternalReferenceSet {
      let urls = ["https://i.imgur.com/a.png", "https://i.imgur.com/b.png"]
      return ExternalReferenceSet(
        references: urls.map {
          ExternalReference(
            projectSlug: "astro", sourceReference: "posts/a.md#L1", rawURL: $0, kind: "markdown", domain: .other,
            match: nil)
        }, projectSources: [:])
    }
  }

  /// Prepared, the sheet up, with the target projects' switches as given.
  private func prepared(
    _ compression: [ExternalMigrationCompressionTarget], migratable: Int = 47
  ) async throws -> (ExternalsModel, ExternalsMigrationTests.StubMigrator, URL) {
    let migrator = ExternalsMigrationTests.StubMigrator()
    migrator.preparation = ExternalsMigrationTests.preparation(migratable: migratable)
    migrator.preparation.compression = compression
    let (database, directory) = try makeUITestDatabase()
    let gallery = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbs"),
        fetcher: { _ in throw URLError(.unsupportedURL) }),
      externalReader: Rows(), externalsMigrator: migrator)
    let model = gallery.externals
    await model.load()
    model.domain = .other
    await model.migrate(model.items ?? [])
    #expect(model.isMigrationSheetPresented)
    // The sample preparation's one unclean source.
    model.setMigrationSource("astro/astro-blog", allowed: true)
    return (model, migrator, directory)
  }

  @Test("The box starts as the target project's switch and apply is told what it says")
  func sheetFollowsProject() async throws {
    let (on, onMigrator, onDirectory) = try await prepared([.init(projectName: "astro", compresses: true)])
    defer { try? FileManager.default.removeItem(at: onDirectory) }
    let confirmation = try #require(on.migrationConfirmation)
    #expect(ExternalMigrationConfirmation.compressTitle == "Compress images")
    #expect(confirmation.compressSubtitle == "Uses astro's compression settings.")
    #expect(on.migrationCompression == [true])
    await on.confirmMigration()
    #expect(onMigrator.compressions == [.on])

    let (off, offMigrator, offDirectory) = try await prepared([.init(projectName: "astro", compresses: false)])
    defer { try? FileManager.default.removeItem(at: offDirectory) }
    #expect(off.migrationCompression == [false])
    await off.confirmMigration()
    #expect(offMigrator.compressions == [.off])
  }

  @Test("Ticking or unticking the box overrides the project")
  func sheetOverride() async throws {
    let (model, migrator, directory) = try await prepared([.init(projectName: "astro", compresses: false)])
    defer { try? FileManager.default.removeItem(at: directory) }
    model.migrationCompression = [true]
    await model.confirmMigration()
    #expect(migrator.compressions == [.on])
  }

  @Test("Projects that disagree: mixed follows each project, a click sets them all")
  func sheetMixed() async throws {
    let (model, migrator, directory) = try await prepared([
      .init(projectName: "astro", compresses: true), .init(projectName: "notes", compresses: false),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.migrationConfirmation?.compressSubtitle == "Uses each project's compression settings.")
    #expect(model.migrationCompression == [true, false])
    #expect(model.migrationCompressionChoice == .project)
    model.migrationCompression = [false, false]
    #expect(model.migrationCompressionChoice == .off)
    await model.confirmMigration()
    #expect(migrator.compressions == [.off])
  }

  @Test("Nothing to upload: no box, and apply follows the projects")
  func sheetNothingToUpload() async throws {
    let (model, _, directory) = try await prepared(
      [.init(projectName: "astro", compresses: true)], migratable: 0)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.migrationConfirmation?.compression.isEmpty == true)
    #expect(model.migrationCompression.isEmpty)
    #expect(model.migrationCompressionChoice == .project)
  }

  @Test("The app's migrator reads each target project's switch once, in order")
  func targetsFromCatalog() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CatalogConfiguration.setCompression(slug: "notes", in: database) { $0.isEnabled = true }
    let projects = try CatalogConfiguration.projects(in: database)
    let targets = CatalogExternalsMigrator.compressionTargets(
      [
        ExternalMigrationTarget(project: "notes", urls: ["a"]),
        ExternalMigrationTarget(project: "blog", urls: ["b"]),
        ExternalMigrationTarget(project: "notes", urls: ["c"]),
      ], projects: projects)
    #expect(
      targets == [
        .init(projectName: "Notes", compresses: true), .init(projectName: "Blog", compresses: false),
      ])
  }
}
