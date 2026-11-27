import AppKit
import CatalogCore
import Foundation
@testable import PinaxUI
import SwiftUI
import Testing

/// Appearance, Drop Zone and Maintenance on the shared settings form
/// parts. Moved and renamed controls still write their old preference
/// keys; the Drop Zone switch dims and disables the rest; Maintenance's
/// verdict card; the panes' key sizes.
///
/// Views are read as values (Mirror) or hosted off screen, never opened.
@MainActor
@Suite(.serialized) struct SettingsAppearanceDropZoneTests {
  private func makeStore() throws -> (PreferencesStore, UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: "pinaxui-s3-\(UUID().uuidString)"))
    return (PreferencesStore(defaults: defaults), defaults)
  }

  /// The first `Binding<T>` anywhere inside `value`.
  private func binding<T>(_ type: T.Type, in value: Any) -> Binding<T>? {
    if let found = value as? Binding<T> { return found }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class { return nil }
    for child in mirror.children {
      if let found = binding(type, in: child.value) { return found }
    }
    return nil
  }

  /// The switch titled `title` in `body`, as its binding.
  private func toggle(_ title: String, in body: Any) throws -> Binding<Bool> {
    let switches = allViews(in: body, typePrefix: "SettingsRowSwitch").compactMap { $0 as? SettingsRowSwitch }
    let match = try #require(switches.first { $0.title == title }, "no switch \(title)")
    return match.$isOn
  }

  // MARK: Appearance

  @Test("The Dark Mode switch is Match System Appearance's key; Light Mode and Dark Mode send the icons to their own keys")
  func appearanceKeys() throws {
    let (store, defaults) = try makeStore()
    let ids = DockIconCatalog.icons.map(\.id)
    let pane = AppearanceSettingsPane(preferences: store)
    #expect(allViews(in: pane.body, typePrefix: "Picker<Text, DockIconMode").isEmpty, "one icon: no switch")

    // One icon: the picker writes the one key.
    var picker = try #require(firstPicker(in: pane))
    picker.$selection.wrappedValue = ids[1]
    #expect(defaults.string(forKey: "pinax.appearance.dockIcon") == ids[1])

    try toggle("Use a different icon in Dark Mode", in: pane.body).wrappedValue = true
    #expect(defaults.bool(forKey: "pinax.appearance.dockIcon.matchesSystem"))
    #expect(allViews(in: pane.body, typePrefix: "Picker<Text, DockIconMode").count == 1)

    picker = try #require(firstPicker(in: AppearanceSettingsPane(preferences: store, editing: .light)))
    picker.$selection.wrappedValue = ids[2]
    #expect(defaults.string(forKey: "pinax.appearance.dockIcon.light") == ids[2])
    picker = try #require(firstPicker(in: AppearanceSettingsPane(preferences: store, editing: .dark)))
    picker.$selection.wrappedValue = ids[5]
    #expect(defaults.string(forKey: "pinax.appearance.dockIcon.dark") == ids[5])
    #expect(defaults.string(forKey: "pinax.appearance.dockIcon.light") == ids[2], "Dark leaves Light alone")
    #expect(defaults.string(forKey: "pinax.appearance.dockIcon") == ids[1])
  }

  private func firstPicker(in pane: AppearanceSettingsPane) -> DockIconPicker? {
    allViews(in: pane.body, typePrefix: "DockIconPicker").first as? DockIconPicker
  }

  @Test("The menu bar's three pickers keep their keys")
  func menuBarKeys() throws {
    let (store, defaults) = try makeStore()
    let body = AppearanceSettingsPane(preferences: store).body
    let unit = try #require(binding(MenuBarChartUnit.self, in: body))
    unit.wrappedValue = .month
    #expect(defaults.string(forKey: "pinax.menuBar.chartUnit") == "month")
    let split = try #require(binding(MenuBarStorageSplit.self, in: body))
    let other = try #require(MenuBarStorageSplit.allCases.first { $0 != store.menuBarStorageSplit })
    split.wrappedValue = other
    #expect(defaults.string(forKey: "pinax.menuBar.storageSplit") == other.rawValue)
  }

  // MARK: Drop Zone

  @Test("Uploads, Showing and Look write the keys the nine old groups wrote")
  func dropZoneKeys() throws {
    let (store, defaults) = try makeStore()
    let body = DropZoneSettingsPane(preferences: store).body
    for (title, key) in [
      ("Show drop zone while dragging", "pinax.dropZone.enabled"),
      ("Copy links when a batch finishes", "pinax.dropZone.copiesURLsOnUpload"),
      ("Always review", "pinax.dropZone.alwaysReviews"),
      ("Only while holding a key", "pinax.dropZone.requiresModifier"),
      ("Follow the pointer across displays", "pinax.dropZone.followsCursor"),
    ] {
      let isOn = try toggle(title, in: body)
      isOn.wrappedValue = !isOn.wrappedValue
      #expect(defaults.object(forKey: key) as? Bool == isOn.wrappedValue, "\(title)")
    }
    let corner = try #require(
      allViews(in: body, typePrefix: "DropZoneCornerPicker").first as? DropZoneCornerPicker)
    corner.$selection.wrappedValue = .topRight
    #expect(defaults.string(forKey: "pinax.dropZone.corner") == "topRight")
    let modifier = try #require(binding(DropZoneModifier.self, in: body))
    modifier.wrappedValue = .command
    #expect(defaults.string(forKey: "pinax.dropZone.modifier") == "command")
    #expect(DropZoneAppearance.allCases.map(\.segmentLabel) == ["Light", "Dark", "Auto"])
    #expect(DropZoneSettingsPane.sizeSubtitle.hasPrefix("Width 280–560, height 320–800."))
  }

  /// Each titled control under `view` (a `SettingsRowSwitch` or a
  /// `SettingsMenuPicker`) with whether the `.disabled` modifiers above it
  /// leave it enabled. SwiftUI draws a `Menu` without an `NSControl` and
  /// the hosted `NSControl`s carry no names, so the value tree is read.
  private func controlStates(in view: Any, enabled: Bool = true) -> [String: Bool] {
    let name = String(describing: type(of: view))
    if let row = view as? SettingsRowSwitch { return ["switch " + row.title: enabled] }
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
      // `.disabled(x)` is a transform of the environment's `isEnabled`.
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

  @Test("With the switch off everything under it is disabled; Key is disabled until its switch is on")
  func dropZoneDisabling() throws {
    let (store, _) = try makeStore()
    func states() -> [String: Bool] {
      controlStates(in: DropZoneSettingsPane(preferences: store).body)
    }
    let master = "switch Show drop zone while dragging"
    store.isDropZoneEnabled = true
    store.dropZoneRequiresModifier = false
    let on = states()
    store.dropZoneRequiresModifier = true
    let withKey = states()
    store.isDropZoneEnabled = false
    let off = states()

    #expect(on.count > 5, "controls found: \(on.keys.sorted())")
    #expect(on["menu Key"] == false && withKey["menu Key"] == true && off["menu Key"] == false)
    #expect(on["switch Only while holding a key"] == true)
    #expect(withKey.filter { !$0.value }.isEmpty, "everything is on: \(withKey)")
    #expect(on.filter { !$0.value }.keys.sorted() == ["menu Key"], "only Key waits for its switch: \(on)")
    #expect(off[master] == true, "the master switch stays on")
    #expect(off.filter { $0.key != master }.allSatisfy { !$0.value }, "the rest is disabled: \(off)")
    for title in ["menu Upload into", "switch Copy links when a batch finishes", "switch Follow the pointer across displays"] {
      #expect(on[title] == true && off[title] == false, Comment(rawValue: title))
    }
  }

  // MARK: Maintenance

  private func report(_ statuses: [DoctorStatus]) -> DoctorReport {
    DoctorReport(checks: statuses.enumerated().map { DoctorCheck(name: "c\($0)", status: $1, detail: "d") })
  }

  @Test("The verdict card's words and symbol, and when the checks ran")
  func maintenanceVerdict() {
    typealias C = MaintenanceSettingsContent
    #expect(C.summary(for: report([.pass, .warning, .info])) == "1 warning, nothing failed")
    #expect(C.summary(for: report([.warning, .warning, .failure])) == "2 warnings, 1 failed")
    #expect(C.summary(for: report([.pass, .info])) == "No warnings, nothing failed")
    #expect(C.overallStatus(report([.pass, .info])) == .pass)
    #expect(C.overallStatus(report([.pass, .warning])) == .warning)
    #expect(C.overallStatus(report([.failure, .warning])) == .failure)
    let checked = Date(timeIntervalSince1970: 1_000_000)
    let english = Locale(identifier: "en_US")
    #expect(C.checkedText(at: checked, now: checked.addingTimeInterval(59), locale: english) == "Checked just now")
    #expect(
      C.checkedText(at: checked, now: checked.addingTimeInterval(300), locale: english)
        == "Checked 5 minutes ago")
    // Each check's id is its row's help tag, its name in sentence case.
    let row = DoctorCheckRow(
      check: DoctorCheck(name: "usage-membership", status: .warning, detail: "d"), usageSync: nil)
    #expect(row.helpTag == "usage-membership")
    #expect(DoctorCheckRow.title("usage-membership") == "Usage membership")
  }

  // MARK: Sizes

  @Test("The panes' key sizes")
  func sizes() {
    typealias m = DesignMetrics.settings
    #expect(m.appIconColumns == 7 && m.appIconTileSize == 52)
    #expect(m.appIconRingRadius == 15 && m.appIconRingPadding == 3 && m.appIconRingWidth == 2.5)
    #expect(m.cornerScreenWidth == 76 && m.cornerScreenHeight == 48)
    #expect(m.cornerWidth == 16 && m.cornerHeight == 11 && m.cornerInset == 5)
    #expect(m.switchCardIconSize == 32 && m.statusCardSymbolSize == 32 && m.checkSymbolSize == 16)
    #expect(m.disabledOpacity == 0.45)
    #expect(DockIconCatalog.icons.count == m.appIconColumns, "all icons in one row")
  }
}
