import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// A command source's Label, Command and Run in, in rows under it, with Test
/// Run and its result. Return in a field, or Set, commits all three. Test Run
/// runs what is stored, so it Sets first.
struct CommandSourceEditor: View {
  let source: ProjectSource
  /// Begun by Add Command… and not yet stored.
  let isNew: Bool
  let slug: String
  @ObservedObject var model: ProjectSettingsModel
  /// The stored source's label after a write.
  let saved: (String) -> Void
  @State private var fields: CommandSourceFields
  @FocusState private var commandFocused: Bool

  init(
    source: ProjectSource, isNew: Bool, slug: String, model: ProjectSettingsModel,
    saved: @escaping (String) -> Void
  ) {
    self.source = source
    self.isNew = isNew
    self.slug = slug
    self.model = model
    self.saved = saved
    _fields = State(initialValue: CommandSourceFields(source))
  }

  /// Set is off until something changed, and while a new source lacks its
  /// command or folder.
  static func canSet(_ fields: CommandSourceFields, source: ProjectSource, isNew: Bool) -> Bool {
    isNew ? fields.isComplete : fields != CommandSourceFields(source)
  }

  var body: some View {
    let test = isNew ? nil : model.commandTest(of: source, inProject: slug)
    VStack(alignment: .leading, spacing: Metrics.sourceFieldSpacing) {
      row("Label") {
        TextField("Label", text: $fields.label)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .onSubmit(apply)
      }
      row("Command") {
        TextField("Command", text: $fields.command)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .pinaxSettingsChip()
          .focused($commandFocused)
          .onSubmit(apply)
      }
      row("Run in") {
        Text(verbatim: SourceRowView.shortPath(fields.workingDirectory))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(fields.workingDirectory)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Choose…", action: chooseDirectory)
          .controlSize(.small)
      }
      row("") {
        Button("Test Run", action: testRun)
          .controlSize(.small)
          .disabled(!fields.isComplete || test?.outcome == .running)
        CommandTestResult(test: test)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Set", action: apply)
          .disabled(!Self.canSet(fields, source: source, isNew: isNew))
      }
    }
    .padding(.vertical, Metrics.rowVerticalPadding)
    .padding(.horizontal, Metrics.rowHorizontalPadding)
    .onAppear { if isNew { commandFocused = true } }
  }

  private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: Metrics.rowSpacing) {
      Text(title)
        .pinaxSettingsValue()
        .frame(width: Metrics.sourceFieldLabelWidth, alignment: .leading)
      content()
    }
  }

  private func chooseDirectory() {
    if let path = model.chooseRunDirectory(startingAt: fields.workingDirectory) {
      fields.workingDirectory = path
    }
  }

  private func apply() {
    guard Self.canSet(fields, source: source, isNew: isNew) else { return }
    if let stored = model.saveCommandSource(
      fields, replacing: isNew ? nil : source.label, inProject: slug)
    {
      saved(stored.label)
    }
  }

  private func testRun() {
    if let ran = model.runCommandTest(
      fields, label: isNew ? nil : source.label, inProject: slug)
    {
      saved(ran.label)
    }
  }
}

/// Beside Test Run: a spinner while it runs, then the references and the time
/// it took, or the failure on one line with all of it as the help.
struct CommandTestResult: View {
  let test: CommandTest?

  var body: some View {
    if let test {
      HStack(spacing: Metrics.commandTestSpacing) {
        switch test.outcome {
        case .running:
          ProgressView().controlSize(.small)
        case .succeeded:
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
          Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
        if let text = test.text {
          Text(verbatim: text)
            .pinaxSettingsRowSubtitle()
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .help(Self.help(test))
        }
      }
    } else {
      Color.clear.frame(height: 0)
    }
  }

  static func help(_ test: CommandTest) -> String {
    if case let .failed(_, detail) = test.outcome { return detail }
    return test.text ?? ""
  }
}
