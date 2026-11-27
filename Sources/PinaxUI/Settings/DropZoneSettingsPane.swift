import AppKit
import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// Drop zone placement and behaviour, modelled on Clop's own settings
/// because Clop is the app being collided with, plus where uploads go, the
/// panel's size and its look: the switch on a card of its own, the rest in
/// Uploads, Showing and Look.
/// Every row binds to the preferences store; none of them touches the
/// catalog.
struct DropZoneSettingsPane: View {
  @ObservedObject var preferences: PreferencesStore
  /// Upload into's fixed choices.
  var projects: [Project] = []

  /// A fixed project that is gone shows as Current Project, which is what
  /// it means.
  var uploadIntoChoice: DropZoneUploadInto {
    preferences.dropZoneUploadInto.resolved(projects: projects.map(\.slug))
  }

  /// Upload into's chosen value, as its menu names it.
  private var uploadIntoName: String {
    switch uploadIntoChoice {
    case .currentProject: "Current Project"
    case .noProject: "No Project"
    case .project(let slug): projects.first { $0.slug == slug }?.name ?? slug
    }
  }

  private var uploadInto: Binding<DropZoneUploadInto> {
    Binding(get: { uploadIntoChoice }, set: { preferences.dropZoneUploadInto = $0 })
  }

  private func sizeBinding(_ axis: WritableKeyPath<CGSize, CGFloat>) -> Binding<Double> {
    Binding(
      get: { Double(preferences.dropZoneSize[keyPath: axis]) },
      set: { value in
        var size = preferences.dropZoneSize
        size[keyPath: axis] = CGFloat(value)
        preferences.setDropZoneSize(size)
      })
  }

  /// "Width 280–560, height 320–800. …", from the preference's own ranges.
  static var sizeSubtitle: String {
    func span(_ range: ClosedRange<Double>) -> String {
      "\(Int(range.lowerBound))–\(Int(range.upperBound))"
    }
    return "Width \(span(DropZoneSize.widthRange)), height \(span(DropZoneSize.heightRange)). "
      + "Dragging the panel's edge also changes it."
  }

  var body: some View {
    HStack(alignment: .top, spacing: DesignMetrics.spacing.none) {
      form
        .frame(width: Metrics.contentWidth)
      // Beside the form and still while it scrolls; level with the switch.
      DropZonePreviewColumn(preferences: preferences, projects: projects)
        .padding(.top, Metrics.pageTopInset)
        .padding(.trailing, Metrics.previewTrailingInset)
    }
  }

  private var form: some View {
    SettingsPage {
      SettingsGroup {
        HStack(spacing: Metrics.rowSpacing) {
          SettingsIcon(kind: .dropZone, size: Metrics.switchCardIconSize)
          SettingsRowLabel(
            title: "Show drop zone while dragging",
            subtitle: "Watches for image drags anywhere and offers to upload them.")
          SettingsRowSwitch("Show drop zone while dragging", isOn: $preferences.isDropZoneEnabled)
        }
        .padding(.vertical, Metrics.switchCardVerticalPadding)
        .padding(.horizontal, Metrics.rowHorizontalPadding)
      }

      Group {
        uploads
        showing
        look
      }
      .disabled(!preferences.isDropZoneEnabled)
      .opacity(preferences.isDropZoneEnabled ? 1 : Metrics.disabledOpacity)
    }
  }

  private var uploads: some View {
    SettingsSection("Uploads") {
      SettingsGroup {
        SettingsRow(
          "Upload into",
          subtitle: "Current Project follows the main window. A fixed project is only where the panel starts."
        ) {
          SettingsMenuPicker("Upload into", selection: uploadInto) {
            Text("Current Project").tag(DropZoneUploadInto.currentProject)
            Text("No Project").tag(DropZoneUploadInto.noProject)
            if !projects.isEmpty {
              Divider()
              ForEach(projects, id: \.slug) { project in
                Text(project.name).tag(DropZoneUploadInto.project(project.slug))
              }
            }
          } label: {
            Text(uploadIntoName)
          }
        }
        SettingsRowDivider()
        SettingsRow("Copy links when a batch finishes", subtitle: "Uses the default format from General.") {
          SettingsRowSwitch("Copy links when a batch finishes", isOn: $preferences.copiesURLsOnUpload)
        }
        SettingsRowDivider()
        SettingsRow("Hide the panel after uploads finish") {
          SettingsMenuPicker("Hide the panel after uploads finish", selection: $preferences.dropZoneAutoHideSeconds) {
            ForEach(DropZoneAutoHide.choices, id: \.self) { seconds in
              Text(DropZoneAutoHide.label(seconds)).tag(seconds)
            }
          } label: {
            Text(DropZoneAutoHide.label(preferences.dropZoneAutoHideSeconds))
          }
        }
        SettingsRowDivider()
        SettingsRow("Always review", subtitle: "Or hold ⇧ when you drop.") {
          SettingsRowSwitch("Always review", isOn: $preferences.dropZoneAlwaysReviews)
        }
      }
    }
  }

  private var showing: some View {
    SettingsSection("Showing") {
      SettingsGroup {
        SettingsRow("Only while holding a key", subtitle: "Pick a key Clop doesn't use, or both panels appear.") {
          SettingsMenuPicker("Key", selection: $preferences.dropZoneModifier) {
            ForEach(DropZoneModifier.allCases, id: \.self) { modifier in
              Text(modifier.label).tag(modifier)
            }
          } label: {
            Text(preferences.dropZoneModifier.label)
          }
          .disabled(!preferences.dropZoneRequiresModifier)
          .opacity(preferences.dropZoneRequiresModifier ? 1 : Metrics.disabledOpacity)
          SettingsRowSwitch("Only while holding a key", isOn: $preferences.dropZoneRequiresModifier)
        }
        SettingsRowDivider()
        SettingsRow("Follow the pointer across displays") {
          SettingsRowSwitch("Follow the pointer across displays", isOn: $preferences.dropZoneFollowsCursor)
        }
        SettingsRowDivider()
        SettingsRow("Position on screen") {
          Text(preferences.dropZoneCorner.label)
            .pinaxSettingsValue()
          DropZoneCornerPicker(selection: $preferences.dropZoneCorner)
        }
        .padding(.vertical, Metrics.cornerRowVerticalPadding - Metrics.rowVerticalPadding)
      }
    }
  }

  private var look: some View {
    SettingsSection("Look") {
      SettingsGroup {
        SettingsRow("Appearance") {
          Picker("Appearance", selection: $preferences.dropZoneAppearance) {
            ForEach(DropZoneAppearance.allCases, id: \.self) { appearance in
              Text(appearance.segmentLabel).tag(appearance)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .fixedSize()
        }
        SettingsRowDivider()
        SettingsRow("Layout", subtitle: "Shelf shows two columns of large thumbnails.") {
          Picker("Layout", selection: $preferences.dropZoneLayout) {
            ForEach(DropZoneLayout.allCases, id: \.self) { layout in
              Text(layout.label).tag(layout)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .fixedSize()
        }
        SettingsRowDivider()
        SettingsRow("Size", subtitle: Self.sizeSubtitle) {
          HStack(spacing: Metrics.sizeFieldSpacing) {
            sizeField("Width", \.width, in: DropZoneSize.widthRange)
            Text(verbatim: "×").pinaxSettingsValue()
            sizeField("Height", \.height, in: DropZoneSize.heightRange)
            Text("pt").pinaxSettingsValue()
          }
          .fixedSize()
        }
        SettingsRowDivider()
        HStack {
          Spacer()
          Button("Reset to Default Size") { preferences.resetDropZoneSize() }
            .buttonStyle(.link)
            .pinaxSettingsLink()
            .disabled(preferences.dropZoneSize == DropZoneSize.defaultSize)
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.linkRowMinHeight)
      }
    }
  }

  /// A number field and its stepper, one axis of the panel's size; the
  /// store clamps what either writes to the range.
  private func sizeField(_ title: String, _ axis: WritableKeyPath<CGSize, CGFloat>, in range: ClosedRange<Double>)
    -> some View
  {
    HStack(spacing: DesignMetrics.spacing.none) {
      TextField(title, value: sizeBinding(axis), format: .number.precision(.fractionLength(0)))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: Metrics.sizeFieldWidth)
      Stepper(title, value: sizeBinding(axis), in: range, step: Metrics.sizeStep)
        .labelsHidden()
    }
  }
}

extension DropZoneAppearance {
  /// The Look segment's word (`New-DropZone`: Light / Dark / Auto); the
  /// preference's own label stays for other places.
  var segmentLabel: String {
    self == .system ? "Auto" : label
  }
}

/// Position on screen (`New-DropZone` `.screen`): a little screen with a
/// button in each corner, the chosen one in the accent.
struct DropZoneCornerPicker: View {
  @Binding var selection: DropZoneCorner

  var body: some View {
    let screen = RoundedRectangle(cornerRadius: Metrics.cornerScreenRadius, style: .continuous)
    ZStack {
      screen
        .fill(
          LinearGradient(
            colors: [PinaxPalette.Settings.cornerScreenTop, PinaxPalette.Settings.cornerScreenBottom],
            startPoint: .top, endPoint: .bottom))
        .overlay(screen.strokeBorder(PinaxPalette.Settings.cornerScreenEdge, lineWidth: Metrics.groupRingWidth))
      ForEach(DropZoneCorner.allCases, id: \.self) { corner in
        cornerButton(corner)
          .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: Self.alignment(corner))
      }
      .padding(Metrics.cornerInset)
    }
    .frame(width: Metrics.cornerScreenWidth, height: Metrics.cornerScreenHeight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Position on screen")
  }

  static func alignment(_ corner: DropZoneCorner) -> Alignment {
    switch corner {
    case .topLeft: .topLeading
    case .topRight: .topTrailing
    case .bottomLeft: .bottomLeading
    case .bottomRight: .bottomTrailing
    }
  }

  private func cornerButton(_ corner: DropZoneCorner) -> some View {
    let isSelected = corner == selection
    let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
    return Button {
      selection = corner
    } label: {
      shape
        .fill(isSelected ? PinaxPalette.Settings.systemAccent : PinaxPalette.Settings.corner)
        .overlay {
          if !isSelected {
            shape.strokeBorder(PinaxPalette.Settings.cornerEdge, lineWidth: Metrics.groupRingWidth)
          }
        }
        .frame(width: Metrics.cornerWidth, height: Metrics.cornerHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(corner.label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
