import CatalogCore
import CoreGraphics

import Foundation
import ImageIO
import GRDB
import PinaxUI
import SwiftUI

func makeUITestDatabase() throws -> (database: DatabasePool, directory: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("pinaxui-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let database = try Database.open(at: directory.appendingPathComponent("catalog.sqlite"))
  try Database.migrate(database)
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO backend
          (id, slug, kind, endpoint, bucket, region, url_prefix, keychain_ref, meta,
           created_at, updated_at)
        VALUES
          (1, 'r2', 's3', 'https://storage.example.com', 'images', 'auto',
           'https://img.example.com', 'backend.r2', '{}',
           '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        INSERT INTO project
          (id, slug, name, key_prefix, backend_id, last_scan_id, created_at, updated_at)
        VALUES
          (1, 'blog', 'Blog', 'blog', 1, NULL, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
          (2, 'notes', 'Notes', 'notes', 1, NULL, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
        """
    )
  }
  return (database, directory)
}

func seedAsset(
  _ database: DatabasePool,
  index: Int,
  uploadedAt: String,
  origFilename: String? = nil,
  projectSlug: String? = "blog",
  tag: String? = nil,
  key: String? = nil,
  width: Int = 800,
  height: Int = 600,
  meta: String = "{}"
) throws {
  try database.write { db in
    var asset = Asset(
      sha256: String(format: "%064x", index + 1),
      backendID: 1,
      key: key ?? "\(projectSlug ?? "x")/asset-\(index).png",
      byteSize: Int64(1000 + index),
      width: width,
      height: height,
      mime: "image/png",
      originalFilename: origFilename ?? "asset-\(index).png",
      meta: meta,
      uploadedAt: uploadedAt,
      createdAt: uploadedAt,
      updatedAt: uploadedAt
    )
    try asset.insert(db)
    if let projectSlug {
      try db.execute(
        sql: """
          INSERT INTO asset_project (asset_id, project_id, added_at)
          SELECT a.id, p.id, ? FROM asset a, project p
          WHERE a.sha256 = ? AND p.slug = ?
          """,
        arguments: [uploadedAt, asset.sha256, projectSlug]
      )
    }
    if let tag {
      try db.execute(sql: "INSERT INTO tag (name) VALUES (?) ON CONFLICT(name) DO NOTHING", arguments: [tag])
      try db.execute(
        sql: """
          INSERT INTO asset_tag (asset_id, tag_id)
          SELECT a.id, t.id FROM asset a, tag t WHERE a.sha256 = ? AND t.name = ?
          """,
        arguments: [asset.sha256, tag]
      )
    }
  }
}

/// Records `count` live references to one asset inside a project's latest scan.
/// Each call starts a new scan and re-points the project's `last_scan_id`, so
/// references seeded by an earlier call stop counting as live — the same
/// supersession rule the scanner itself applies.
func seedLiveUsage(
  _ database: DatabasePool,
  projectSlug: String,
  sha256: String,
  count: Int
) throws {
  try database.write { db in
    try db.execute(
      sql: """
        INSERT INTO scan (project_id, started_at, finished_at, coverage, found_count)
        SELECT id, '2026-08-20T13:00:00Z', '2026-08-20T13:00:00Z', '[]', 0
        FROM project WHERE slug = ?
        """,
      arguments: [projectSlug]
    )
    try db.execute(
      sql: "UPDATE project SET last_scan_id = (SELECT MAX(id) FROM scan) WHERE slug = ?",
      arguments: [projectSlug]
    )
    for occurrence in 0..<count {
      try db.execute(
        sql: """
          INSERT INTO usage
            (project_id, asset_id, raw_url, source_ref, first_seen, last_seen, last_scan_id)
          SELECT p.id, a.id, ?, ?, '2026-08-20T13:00:00Z', '2026-08-20T13:00:00Z', p.last_scan_id
          FROM project p, asset a WHERE p.slug = ? AND a.sha256 = ?
          """,
        arguments: [
          "https://img.example.com/\(sha256.prefix(12)).png",
          "posts/hello.md#\(occurrence)",
          projectSlug,
          sha256,
        ]
      )
    }
  }
}

/// Renders a solid-color JPEG entirely in-process so thumbnail tests never touch
/// the network or bundled fixtures.
func makeJPEGData(width: Int = 64, height: Int = 48) -> Data? {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return nil }
  context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  guard let image = context.makeImage() else { return nil }
  let mutable = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(
    mutable,
    "public.jpeg" as CFString,
    1,
    nil
  ) else { return nil }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { return nil }
  return mutable as Data
}

/// The action of the first `Button` in a view body whose label matches. A
/// `Button` keeps its label and a `ButtonAction.closure(_)` as stored
/// properties (measured on macOS 15), so a test can press the button the
/// app itself declares instead of calling the model behind it.
@MainActor
func buttonAction(in view: Any, label matches: (Any) -> Bool) -> (() -> Void)? {
  let mirror = Mirror(reflecting: view)
  if String(describing: type(of: view)).hasPrefix("Button<"),
    let label = mirror.descendant("label"), matches(label)
  {
    let action = mirror.descendant("action", "closure")
    if let action = action as? @MainActor () -> Void {
      return { MainActor.assumeIsolated { action() } }
    }
    return action as? () -> Void
  }
  for child in mirror.children {
    if let found = buttonAction(in: child.value, label: matches) { return found }
  }
  return nil
}

/// Whether the first `Button` (or `control`, e.g. `"Menu<"`) whose label
/// matches is enabled, as its own
/// view body declares it: every `.disabled(_:)` on the way down is an
/// `_EnvironmentKeyTransformModifier<Bool>` over `\.isEnabled` whose
/// transform is applied here in order (measured on macOS 15). Stops at
/// class instances, so it never walks an observed object's graph.
@MainActor
func buttonIsEnabled(
  in view: Any, label matches: (Any) -> Bool, enabled: Bool = true, control: String = "Button<"
) -> Bool? {
  let mirror = Mirror(reflecting: view)
  if mirror.displayStyle == .class { return nil }
  if String(describing: type(of: view)).hasPrefix(control),
    let label = mirror.descendant("label"), matches(label)
  {
    return enabled
  }
  var enabled = enabled
  if let modifier = mirror.descendant("modifier"),
    let keyPath = Mirror(reflecting: modifier).descendant("keyPath")
      as? WritableKeyPath<EnvironmentValues, Bool>,
    keyPath == \EnvironmentValues.isEnabled,
    let transform = Mirror(reflecting: modifier).descendant("transform") as? (inout Bool) -> Void
  {
    transform(&enabled)
  }
  for child in mirror.children {
    if let found = buttonIsEnabled(
      in: child.value, label: matches, enabled: enabled, control: control)
    {
      return found
    }
  }
  return nil
}

/// The keyboard shortcut on the first `Button` whose label matches, as its
/// own view body declares it: `.keyboardShortcut(_:modifiers:)` is a
/// modifier whose `value` is a `KeyboardShortcut?` (the walk
/// `TableGridPatchTests` reads Make Bigger's ⌘+ with). Stops at class
/// instances.
@MainActor
func buttonShortcut(in view: Any, label matches: (Any) -> Bool) -> KeyboardShortcut? {
  func walk(_ value: Any, shortcut: KeyboardShortcut?) -> KeyboardShortcut?? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class { return nil }
    if String(describing: type(of: value)).hasPrefix("Button<"),
      let label = mirror.descendant("label"), matches(label)
    {
      return .some(shortcut)
    }
    var shortcut = shortcut
    if let modifier = mirror.descendant("modifier"),
      let declared = Mirror(reflecting: modifier).descendant("value") as? KeyboardShortcut?,
      let declared
    {
      shortcut = declared
    }
    for child in mirror.children {
      if let found = walk(child.value, shortcut: shortcut) { return found }
    }
    return nil
  }
  return walk(view, shortcut: nil) ?? nil
}

/// The first value in a view tree whose type name starts with `prefix`.
/// Stops at class instances (an `@ObservedObject`'s object graph is not
/// view content, and walking it can run for minutes).
func firstView(in view: Any, typePrefix prefix: String) -> Any? {
  if String(describing: type(of: view)).hasPrefix(prefix) { return view }
  let mirror = Mirror(reflecting: view)
  if mirror.displayStyle == .class { return nil }
  for child in mirror.children {
    if let found = firstView(in: child.value, typePrefix: prefix) { return found }
  }
  return nil
}

/// A Dock icon applier that never touches the real tile:
/// every `PinaxAppModel` a test builds passes it.
@MainActor
func inertDockIcon(_ preferences: PreferencesStore) -> DockIconApplier {
  DockIconApplier(preferences: preferences, image: { _ in nil }, systemIsDark: { false }, setIcon: { _ in })
}

/// Every `T` a view draws, walking PinaxUI views' bodies and SwiftUI's
/// containers by reflection — the closures the app installs, read as
/// values, with nothing hosted or clicked.
@MainActor
func collectViews<T>(_ root: Any, as _: T.Type) -> [T] {
  var found: [T] = []
  var stack: [Any] = [root]
  while let value = stack.popLast() {
    if let match = value as? T {
      found.append(match)
      continue
    }
    // Models are classes that point back at each other; the walk stays
    // in view values.
    if Swift.type(of: value) is AnyClass { continue }
    if let view = value as? any View, let body = ownBody(view) {
      stack.append(body)
    }
    stack.append(contentsOf: Mirror(reflecting: value).children.map(\.value))
  }
  return found
}

/// A PinaxUI view's body; nil for SwiftUI's own views.
@MainActor
private func ownBody<V: View>(_ view: V) -> Any? {
  guard String(reflecting: V.self).hasPrefix("PinaxUI."), V.Body.self != Never.self else {
    return nil
  }
  return view.body
}

/// A defaults suite of its own for the settings window's UI state (list
/// widths), so a hosted page never reads or writes the user's.
func islandTestDefaults() -> UserDefaults {
  UserDefaults(suiteName: "pinaxui-island-\(UUID().uuidString)")!
}

/// The detail beside an island at its first width: the two columns' 748,
/// less the island's 12 margin and 196.
let islandDetailWidth =
  DesignMetrics.settings.listColumnWidth + DesignMetrics.settings.detailWidth
  - DesignMetrics.settings.islandLeadingInset - DesignMetrics.settings.islandDefaultWidth
