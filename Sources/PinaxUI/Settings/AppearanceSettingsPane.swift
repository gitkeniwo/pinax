import AppKit
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// Settings ▸ Appearance ▸ App icon, Menu bar.
/// Writes the preferences only; `DockIconApplier` puts the choice on the
/// Dock tile and `MenuBarIconLabel` on the menu bar item.
struct AppearanceSettingsPane: View {
  @ObservedObject var preferences: PreferencesStore
  /// Which of the two icons the picker sets while "Use a different icon in
  /// Dark Mode" is on.
  @State var editing: DockIconMode = .light

  enum DockIconMode: Hashable {
    case light, dark
  }

  var body: some View {
    SettingsPage {
      SettingsSection(
        "App icon",
        note: "Shown in the Dock and the app switcher. Finder, Launchpad and notifications keep the default icon."
      ) {
        SettingsGroup {
          // The old Match System Appearance, same key and same sense: on
          // means a second icon for Dark Mode.
          SettingsRow("Use a different icon in Dark Mode") {
            SettingsRowSwitch("Use a different icon in Dark Mode", isOn: $preferences.dockIconMatchesSystem)
          }
          SettingsRowDivider()
          VStack(spacing: Metrics.appIconRowSpacing) {
            if preferences.dockIconMatchesSystem {
              Picker("Icon for", selection: $editing) {
                Text("Light Mode").tag(DockIconMode.light)
                Text("Dark Mode").tag(DockIconMode.dark)
              }
              .labelsHidden()
              .pickerStyle(.segmented)
              .fixedSize()
            }
            DockIconPicker(selection: pickerSelection)
          }
          .padding(.top, Metrics.appIconRowTopPadding)
          .padding(.bottom, Metrics.appIconRowBottomPadding)
          .padding(.horizontal, Metrics.rowHorizontalPadding)
          .frame(maxWidth: .infinity)
        }
      }
      SettingsSection("Menu bar", note: "The status item and the chart in its panel.") {
        SettingsGroup {
          SettingsRow("Icon") {
            SettingsMenuPicker("Icon", selection: $preferences.menuBarIconID) {
              ForEach(MenuBarIconCatalog.icons) { icon in
                // Icon only: a menu item takes an `NSImage`, which keeps the
                // template tint; the name stays for VoiceOver.
                Image(nsImage: menuBarThumbnail(icon))
                  .accessibilityLabel(icon.name)
                  .tag(icon.id)
              }
            } label: {
              if let icon = MenuBarIconCatalog.icons.first(where: { $0.id == preferences.menuBarIconID }) {
                Image(nsImage: menuBarThumbnail(icon))
              }
            }
          }
          SettingsRowDivider()
          SettingsRow("Each bar") {
            SettingsMenuPicker("Each bar", selection: $preferences.menuBarChartUnit) {
              ForEach(MenuBarChartUnit.allCases) { unit in
                Text(unit.name).tag(unit)
              }
            } label: {
              Text(preferences.menuBarChartUnit.name)
            }
          }
          SettingsRowDivider()
          SettingsRow("Storage bar") {
            SettingsMenuPicker("Storage bar", selection: $preferences.menuBarStorageSplit) {
              ForEach(MenuBarStorageSplit.allCases) { split in
                Text(split.name).tag(split)
              }
            } label: {
              Text(preferences.menuBarStorageSplit.name)
            }
          }
        }
      }
      // The same value as the sidebar header
      // menu's Hide Section / Show Section.
      SettingsSection("Library tab", note: "Extra sections below Storage.") {
        SettingsGroup {
          ForEach(Array(LibraryShortcut.allCases.enumerated()), id: \.element) { index, shortcut in
            if index > 0 { SettingsRowDivider() }
            Toggle(shortcut.title, isOn: libraryShortcutBinding(shortcut))
              .toggleStyle(.checkbox)
              .padding(.vertical, Metrics.rowVerticalPadding)
              .padding(.horizontal, Metrics.rowHorizontalPadding)
              .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
          }
        }
      }
    }
  }

  /// One Library-tab shortcut's checkbox.
  func libraryShortcutBinding(_ shortcut: LibraryShortcut) -> Binding<Bool> {
    Binding(
      get: { preferences.libraryShortcuts.contains(shortcut) },
      set: { shown in
        if shown {
          preferences.libraryShortcuts.insert(shortcut)
        } else {
          preferences.libraryShortcuts.remove(shortcut)
        }
      })
  }

  /// The icon the picker sets: the one icon, or — with a second for Dark
  /// Mode — the one the Light Mode / Dark Mode switch names.
  var pickerSelection: Binding<String> {
    guard preferences.dockIconMatchesSystem else { return $preferences.dockIconID }
    switch editing {
    case .light:
      return Binding(
        get: { preferences.effectiveDockIconLightID },
        set: { preferences.dockIconLightID = $0 })
    case .dark:
      return $preferences.dockIconDarkID
    }
  }

  private func menuBarThumbnail(_ icon: MenuBarIcon) -> NSImage {
    let image = NSImage(named: icon.assetName) ?? NSImage()
    image.isTemplate = true
    return image
  }
}

/// The app icons in one row of seven: a 52 pt tile, its name on one line
/// under it, the chosen one ringed and named in the accent.
struct DockIconPicker: View {
  @Binding var selection: String

  var body: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: Metrics.appIconColumnSpacing, alignment: .top),
        count: Metrics.appIconColumns),
      spacing: Metrics.appIconColumnSpacing
    ) {
      ForEach(DockIconCatalog.icons) { icon in
        cell(icon)
      }
    }
  }

  private func cell(_ icon: DockIcon) -> some View {
    let isSelected = icon.id == selection
    return Button {
      selection = icon.id
    } label: {
      VStack(spacing: Metrics.appIconNameSpacing) {
        Image(nsImage: thumbnail(icon))
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: Metrics.appIconTileSize, height: Metrics.appIconTileSize)
          .padding(Metrics.appIconRingPadding)
          .overlay {
            if isSelected {
              RoundedRectangle(cornerRadius: Metrics.appIconRingRadius, style: .continuous)
                .strokeBorder(PinaxPalette.Settings.systemAccent, lineWidth: Metrics.appIconRingWidth)
            }
          }
        Text(icon.name)
          .pinaxSettingsIconName(selected: isSelected)
          .foregroundStyle(isSelected ? AnyShapeStyle(PinaxPalette.Settings.systemAccent) : AnyShapeStyle(.primary))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: Metrics.appIconNameWidth)
          .help(icon.name)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(icon.name)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// The bundle icon is the app's own; the others are its asset images
  /// (absent outside the app, where the app's icon stands in).
  private func thumbnail(_ icon: DockIcon) -> NSImage {
    let own = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    guard let asset = icon.assetName else { return own }
    return NSImage(named: asset) ?? own
  }
}
