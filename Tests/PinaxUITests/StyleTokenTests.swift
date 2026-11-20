import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// The gruvbox tokens, the format and domain colours,
/// the sidebar's configured sizes, and the title's project symbol.
@MainActor
@Suite struct StyleTokenTests {
  typealias Token = PinaxPalette.Token

  /// The design palette, copied by hand: (light, dark).
  static let table: [Token: (light: String, dark: String)] = [
    .red: ("#cc241d", "#fb4934"),
    .orange: ("#d65d0e", "#fe8019"),
    .yellow: ("#d79921", "#fabd2f"),
    .green: ("#98971a", "#b8bb26"),
    .blue: ("#458588", "#83a598"),
    .purple: ("#b16286", "#d3869b"),
    .aqua: ("#689d6a", "#8ec07c"),
    .gray: ("#928374", "#a89984"),
    .accent: ("#076678", "#83a598"),
    .accentFill: ("#3d7c80", "#3d7c80"),
    // soft: blue at 16 % / 22 %.
    .soft: ("#458588@0.16", "#83a598@0.22"),
    .count: ("#000000@0.07", "#ffffff@0.10"),
    .grp: ("#000000@0.05", "#ffffff@0.08"),
    .band: ("#000000@0.06", "#ffffff@0.07"),
  ]

  @Test("Every token's light and dark value is the design palette's")
  func tokensMatchTheTable() {
    #expect(Set(Self.table.keys) == Set(Token.allCases))
    for token in Token.allCases {
      let expected = try! #require(Self.table[token])
      #expect(PinaxPalette.value(token, dark: false).description == expected.light, "\(token)")
      #expect(PinaxPalette.value(token, dark: true).description == expected.dark, "\(token)")
    }
  }

  /// The dynamic colour resolves to the right group in each appearance.
  @Test("The dynamic colour follows the drawing appearance")
  func dynamicColourFollowsAppearance() throws {
    for token in Token.allCases {
      for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
        let appearance = try #require(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
          resolved = PinaxPalette.nsColor(token).usingColorSpace(.sRGB)
        }
        let color = try #require(resolved)
        let value = PinaxPalette.value(token, dark: dark)
        #expect(Int((color.redComponent * 255).rounded()) == value.r, "\(token) \(name)")
        #expect(Int((color.greenComponent * 255).rounded()) == value.g, "\(token) \(name)")
        #expect(Int((color.blueComponent * 255).rounded()) == value.b, "\(token) \(name)")
        #expect(abs(Double(color.alphaComponent) - value.alpha) < 0.001, "\(token) \(name)")
      }
    }
  }

  @Test("Formats: JPEG blue, PNG aqua, GIF purple, WEBP orange, others gray")
  func formatColours() {
    #expect(PinaxPalette.formatToken(mime: "image/jpeg") == .blue)
    #expect(PinaxPalette.formatToken(mime: "IMAGE/JPEG") == .blue)
    #expect(PinaxPalette.formatToken(mime: "image/png") == .aqua)
    #expect(PinaxPalette.formatToken(mime: "image/gif") == .purple)
    #expect(PinaxPalette.formatToken(mime: "image/webp") == .orange)
    #expect(PinaxPalette.formatToken(mime: "image/svg+xml") == .gray)
    #expect(PinaxPalette.formatToken(mime: "image/heic") == .gray)
    #expect(PinaxPalette.formatToken(mime: "") == .gray)
    #expect(PinaxPalette.formatBadge(mime: "image/jpeg") == "JPG")
    #expect(PinaxPalette.formatBadge(mime: "image/png") == "PNG")
    #expect(PinaxPalette.formatBadge(mime: "image/webp") == "WEBP")
    #expect(PinaxPalette.formatBadge(mime: "image/svg+xml") == "SVG")
  }

  /// Pinned values: a hash seeded per process (`hashValue`) would move
  /// them between runs; FNV-1a does not.
  @Test("A domain's colour is stable: same domain, same hue, fixed values")
  func domainColoursAreStable() {
    let fixtures: [(String, Token)] = [
      ("img.example.com", Self.pinned["img.example.com"]!),
      ("github.com", Self.pinned["github.com"]!),
      ("cdn.jsdelivr.net", Self.pinned["cdn.jsdelivr.net"]!),
      ("upload.wikimedia.org", Self.pinned["upload.wikimedia.org"]!),
    ]
    for (domain, token) in fixtures {
      #expect(PinaxPalette.domainToken(domain) == token, "\(domain)")
      #expect(PinaxPalette.domainToken(domain.uppercased()) == token, "\(domain) in capitals")
      #expect(PinaxPalette.domainTokens.contains(token))
    }
    #expect(PinaxPalette.stableHash("") == 0xcbf2_9ce4_8422_2325)
    #expect(PinaxPalette.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
    #expect(Set(fixtures.map(\.1)).count > 1, "the fixtures do not all land on one hue")
  }

  static let pinned: [String: Token] = [
    // Cross-checked with an independent FNV-1a in Python.
    "img.example.com": .green,
    "github.com": .yellow,
    "cdn.jsdelivr.net": .purple,
    "upload.wikimedia.org": .blue,
  ]

  @Test("Finder's seven labels take their gruvbox namesakes")
  func labelColours() {
    let expected: [AssetLabel: Token] = [
      .red: .red, .orange: .orange, .yellow: .yellow, .green: .green,
      .blue: .blue, .purple: .purple, .gray: .gray,
    ]
    for label in AssetLabel.allCases {
      #expect(label.token == expected[label], "\(label)")
    }
  }

  @Test("Sidebar categories take their palette hues")
  func sidebarHues() {
    #expect(SidebarIconTint.library.token == .blue)
    #expect(SidebarIconTint.recent.token == .orange)
    #expect(SidebarIconTint.favorites.token == .red)
    #expect(SidebarIconTint.archived.token == .gray)
    #expect(SidebarIconTint.catalog.token == .aqua)
    #expect(SidebarIconTint.overview.token == .green)
    #expect(SidebarIconTint.usage.token == .orange)
    #expect(SidebarIconTint.orphans.token == .purple)
    #expect(SidebarIconTint.externals.token == .aqua)
    #expect(SidebarIconTint.label(.yellow).token == .yellow)
  }

  @Test("Catalog folders are tinted as Catalog, their rows' squares 18; other rows 20")
  func catalogRowsUseTheFolderSquare() {
    let sections = SidebarModel.sections(
      navigator: .library, projects: [], tags: [], months: [],
      folderChildren: [.r2(nil): [(segment: "blog", assetCount: 3, hasSubPrefixes: false)]], catalogRoots: [FixtureBackend.root])
    let folder = try! #require(sections.first { $0.id == "catalog" }?.entries.first?.children.first)
    #expect(folder.iconTint == .catalog)
    #expect(SidebarEntrySquare.size(for: folder.iconTint).side == 18)
    let all = try! #require(sections.first?.entries.first)
    #expect(SidebarEntrySquare.size(for: all.iconTint).side == 20)
  }

  @Test("Sidebar row and part sizes are the configured ones")
  func configuredSizes() {
    #expect(DesignMetrics.sidebarRow.height == 30)
    #expect(DesignMetrics.sidebarRow.contentHeight + DesignMetrics.sidebarRow.listVerticalInset == 30)
    #expect(DesignMetrics.sidebarRow.selectionRadius == 7)
    #expect(DesignMetrics.sidebarRow.selectedRimWidth == 1)
    #expect(DesignMetrics.sidebarRow.countWidth == 34)
    #expect(DesignMetrics.sidebarRow.levelIndent == 26)
    #expect(ColorSquare.Size.sidebar.side == 20 && ColorSquare.Size.sidebar.radius == 5)
    #expect(ColorSquare.Size.folder.side == 18 && ColorSquare.Size.folder.radius == 5)
    #expect(ColorSquare.Size.header.side == 28 && ColorSquare.Size.header.radius == 7)
    #expect(ColorSquare.Size.caption.side == 13 && ColorSquare.Size.caption.radius == 3.5)
    #expect(DesignMetrics.controlGroup.height == 26 && DesignMetrics.controlGroup.radius == 7)
    #expect(DesignMetrics.band.height == 22 && DesignMetrics.band.radius == 5)
    #expect(DesignMetrics.iconButton.width == 26 && DesignMetrics.iconButton.height == 22)
    #expect(DesignMetrics.statPill.height == 28 && DesignMetrics.statPill.radius == 7)
    #expect(DesignMetrics.soft.plateHeight == 22 && DesignMetrics.soft.plateRadius == 6)
  }

  @Test("A section band's chevron: down open, right closed")
  func bandChevron() {
    #expect(SectionBand.chevron(expanded: true) == "chevron.down")
    #expect(SectionBand.chevron(expanded: false) == "chevron.right")
  }

  /// The title's project line shows the stack for All Projects and a
  /// folder for one project — read from the view the toolbar mounts, with
  /// the model's own current project.
  @Test("The title's project symbol switches between All Projects and one project")
  func projectSymbolFollowsTheCurrentProject() throws {
    let (database, directory) = try makeUITestDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GalleryModel(
      catalog: ReadOnlyCatalog(database: database),
      editor: EditableCatalog(database: database),
      thumbnails: ThumbnailCache(
        cacheDirectory: directory.appendingPathComponent("thumbnails", isDirectory: true),
        fetcher: { _ in throw URLError(.unsupportedURL) }))
    func symbols() -> [String] {
      let title = WindowTitle.compose(
        selection: .all, projects: [], currentProjectSlug: model.currentProjectSlug)
      return allViews(in: ProjectTitleItem(model: model, title: title).body, typePrefix: "Image")
        .map { image in
          // The symbol's name sits in the image's provider box.
          var text = ""
          dump(image, to: &text)
          return text
        }
    }
    model.currentProjectSlug = nil
    #expect(symbols().contains { $0.contains("rectangle.stack.fill") }, "\(symbols())")
    #expect(!symbols().contains { $0.contains("\"folder.fill\"") })
    model.currentProjectSlug = "blog"
    #expect(symbols().contains { $0.contains("\"folder.fill\"") }, "\(symbols())")
    #expect(!symbols().contains { $0.contains("rectangle.stack.fill") })
    for name in ["rectangle.stack.fill", "folder.fill", "chevron.down", "chevron.right"] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }
}
