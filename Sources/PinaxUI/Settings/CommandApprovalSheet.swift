import CatalogCore
import SwiftUI

private typealias Metrics = DesignMetrics.settings

/// The question before a command first runs on this Mac: the whole command and
/// the folder it runs in, which this is the one place to read in full. Neither
/// button is the default, so Return runs nothing; Esc cancels.
struct CommandApprovalSheet: View {
  let approval: PendingCommandApproval
  let cancel: () -> Void
  let run: () -> Void

  static let title = "Run this command?"
  static let note = "Pinax runs it as you, with your login shell."

  static func directoryLine(_ approval: PendingCommandApproval) -> String {
    "in \(SourceRowView.shortPath(approval.workingDirectory))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text(Self.title)
        .pinaxTitle()
      card
      Text(Self.note)
        .pinaxBody()
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        Button("Run", action: run)
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: Metrics.commandSheetWidth)
  }

  private var card: some View {
    // A command longer than the sheet can hold scrolls; none of it is cut.
    ViewThatFits(in: .vertical) {
      lines
      ScrollView { lines }
    }
    .frame(maxHeight: Metrics.commandSheetCommandMaxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .background(
      PinaxPalette.Settings.chip,
      in: RoundedRectangle(cornerRadius: Metrics.commandCardRadius, style: .continuous))
  }

  private var lines: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      Text(verbatim: approval.command)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: Self.directoryLine(approval))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(.callout, design: .monospaced))
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, Metrics.commandCardVerticalPadding)
    .padding(.horizontal, Metrics.commandCardHorizontalPadding)
  }
}

/// The command confirmation, shown by whichever window asked for the run.
struct CommandApprovalConfirmation: ViewModifier {
  let model: UsageSyncModel?
  let presenter: UsageSyncPresenter

  func body(content: Content) -> some View {
    if let model {
      content.modifier(Presented(model: model, presenter: presenter))
    } else {
      content
    }
  }

  /// What the window's sheet shows: the pending command, if this window asked.
  /// Only the sheet's buttons answer it. A sheet that is closing writes nil
  /// here, possibly after Run has already moved on to the next command, so
  /// that write cancels nothing.
  @MainActor
  static func item(_ model: UsageSyncModel, presenter: UsageSyncPresenter)
    -> Binding<PendingCommandApproval?>
  {
    Binding(
      get: {
        model.isCommandApprovalPresented(by: presenter) ? model.pendingCommandApproval : nil
      },
      set: { _ in })
  }

  @MainActor
  static func sheet(_ approval: PendingCommandApproval, model: UsageSyncModel)
    -> CommandApprovalSheet
  {
    CommandApprovalSheet(
      approval: approval,
      cancel: { model.cancelCommand() },
      run: { Task { await model.confirmCommand(approval) } })
  }

  private struct Presented: ViewModifier {
    @ObservedObject var model: UsageSyncModel
    let presenter: UsageSyncPresenter

    func body(content: Content) -> some View {
      content.sheet(item: CommandApprovalConfirmation.item(model, presenter: presenter)) {
        CommandApprovalConfirmation.sheet($0, model: model)
      }
    }
  }
}

extension PendingCommandApproval: Identifiable {
  public var id: [String] { [project, label, command, workingDirectory] }
}

extension View {
  func commandApprovalSheet(_ model: UsageSyncModel?, presenter: UsageSyncPresenter)
    -> some View
  {
    modifier(CommandApprovalConfirmation(model: model, presenter: presenter))
  }
}
