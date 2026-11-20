import CatalogCore
import SwiftUI

/// Mounts the domain move's one sheet on the main window: its own view so the window redraws on the move's changes.
struct DomainMigrationSheetMount: ViewModifier {
  let domain: DomainMigrationModel?

  func body(content: Content) -> some View {
    if let domain {
      content.modifier(Mounted(model: domain))
    } else {
      content
    }
  }

  private struct Mounted: ViewModifier {
    @ObservedObject var model: DomainMigrationModel

    func body(content: Content) -> some View {
      content.sheet(
        isPresented: Binding(
          get: { model.sheet != nil },
          set: { if !$0 { model.dismissSheet() } })
      ) {
        DomainMigrationSheet(model: model)
      }
    }
  }
}

/// The sheet, in its three states: fill in, checking, the result (laid
/// out as the external-image migration's confirmation). Every string comes from the model.
struct DomainMigrationSheet: View {
  @ObservedObject var model: DomainMigrationModel

  static let width: CGFloat = 560
  static let rowHeight: CGFloat = 36
  static let rowInset: CGFloat = DesignMetrics.spacing.m

  var body: some View {
    Group {
      switch model.sheet {
      case .form?:
        if let form = model.form { DomainMoveFormView(model: model, form: form) }
      case .checking?:
        checkingView
      case .result?:
        if let summary = model.summary { DomainMoveResultView(model: model, summary: summary) }
      case nil:
        EmptyView()
      }
    }
    .padding(DesignMetrics.spacing.xl)
    .frame(width: Self.width)
    .onExitCommand { model.dismissSheet() }
  }

  // MARK: Checking

  private var checkingView: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      if let request = model.request {
        Text(Self.checkingTitle(request))
          .pinaxTitle()
          .lineLimit(1)
        Text(
          request.keepsPrefix
            ? "Checking each link on the current domain. Nothing changes until you confirm."
            : "Checking each link on the new domain. Nothing changes until you confirm."
        )
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
          ForEach(Array(Self.checkingLines(request).enumerated()), id: \.offset) { index, line in
            if index > 0 { Self.rowDivider }
            DomainMoveLineRow(line: line)
          }
        }
        .domainCard()
        VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
          Text(model.checking.text)
            .monospacedDigit()
            .lineLimit(1)
          ProgressView(value: model.checking.fraction)
            .progressViewStyle(.linear)
        }
      }
      HStack {
        Button("Continue in Background") { model.continueInBackground() }
          .help(DomainCopy.continueHelp)
        Spacer()
        Button("Cancel") { model.cancelCheck() }
          .keyboardShortcut(.cancelAction)
        Button(model.request.map(Self.moveTitle) ?? "Move") {}
          .buttonStyle(.borderedProminent)
          .tint(PinaxPalette.accentFill)
          .disabled(true)
      }
    }
  }

  /// "Move to img2.example.com"; flow B "Move 12 Links to img.example.com".
  static func checkingTitle(_ request: DomainMoveRequest) -> String {
    request.keepsPrefix
      ? "Move \(DomainCopy.links(request.links, capital: true)) to \(request.toHost)"
      : "Move to \(request.toHost)"
  }

  static func moveTitle(_ request: DomainMoveRequest) -> String {
    "Move \(DomainCopy.links(request.links, capital: true))"
  }

  /// Prefix, Old domains, and flow A's Projects.
  static func checkingLines(_ request: DomainMoveRequest) -> [DomainMoveLine] {
    let from = DomainHost.host(request.from)
    var lines = [
      DomainMoveLine(
        label: "Prefix", tone: .prefix,
        value: request.keepsPrefix ? "Unchanged · \(from)" : "\(from) → \(request.toHost)", help: request.to),
      DomainMoveLine(
        label: "Old domains", tone: .oldDomains,
        value: request.keepsPrefix
          ? request.oldDomains.map(DomainHost.host).joined(separator: ", ")
          : request.keepOldDomains || request.oldDomains.isEmpty
            ? "Kept as they are" : "Moved too · \(request.oldDomains.count.formatted())",
        help: request.oldDomains.joined(separator: "\n")),
    ]
    if !request.keepsPrefix {
      lines.append(
        DomainMoveLine(
          label: "Projects", tone: .files,
          value: request.projects.isEmpty ? "All that link to it" : request.projects.joined(separator: ", "),
          help: ""))
    }
    return lines
  }

  static var rowDivider: some View {
    Divider().padding(.leading, rowInset + ColorSquare.Size.sidebar.side + DesignMetrics.spacing.s)
  }
}

/// The fill-in state.
struct DomainMoveFormView: View {
  @ObservedObject var model: DomainMigrationModel
  let form: DomainMoveForm

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text("Move to New Domain")
        .pinaxTitle()
      Text(DomainCopy.formSubtitle)
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignMetrics.spacing.s,
           verticalSpacing: DesignMetrics.spacing.m) {
        GridRow {
          Text("From:").gridColumnAlignment(.trailing)
          Text(form.fromHost).help(form.current)
        }
        GridRow {
          Text("To:")
          VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
            TextField(
              "To", text: Binding(get: { form.to }, set: { model.setTo($0) }),
              prompt: Text(DomainCopy.toPlaceholder))
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .onSubmit { Task { await model.checkLinks() } }
            if let error = form.error {
              Text(error)
                .pinaxCaption()
                .foregroundStyle(PinaxPalette.red)
            }
          }
        }
        if form.showsOldDomainsSwitch {
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            HStack {
              Text("Also move links on old domains")
              Text(PinaxFormat.count(form.oldDomains.count, singular: "old domain"))
                .pinaxCaption()
                .foregroundStyle(.secondary)
              Spacer()
              Toggle(
                "Also move links on old domains",
                isOn: Binding(get: { form.alsoMoveOld }, set: { model.setAlsoMoveOld($0) })
              )
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
            }
          }
        }
        GridRow(alignment: .top) {
          Text("Projects:")
          VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
            if form.isLoading {
              ProgressView().controlSize(.small)
            } else if form.projects.isEmpty {
              Text("No project links to this backend.")
                .foregroundStyle(.secondary)
            }
            ForEach(form.projects) { project in
              Toggle(
                isOn: Binding(
                  get: { form.selected.contains(project.slug) },
                  set: { model.setProject(project.slug, selected: $0) })
              ) {
                HStack(spacing: DesignMetrics.spacing.xs) {
                  Text(project.slug)
                  Text(PinaxFormat.count(project.links, singular: "link"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
              }
              .toggleStyle(.checkbox)
            }
          }
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { model.dismissSheet() }
          .keyboardShortcut(.cancelAction)
        Button("Check Links") { Task { await model.checkLinks() } }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .tint(PinaxPalette.accentFill)
          .disabled(!form.canCheck || model.isBusy)
      }
    }
  }
}

/// The checked move: title, sentence, the summary,
/// failures, already broken links, unclean sources, the tip, the buttons.
struct DomainMoveResultView: View {
  @ObservedObject var model: DomainMigrationModel
  let summary: DomainMoveSummary

  var body: some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.m) {
      Text(summary.title)
        .pinaxTitle()
        .lineLimit(1)
      Text(summary.subtitle)
        .pinaxSecondary()
        .fixedSize(horizontal: false, vertical: true)
      if !summary.isPrefixOnly {
        summaryCard
        if !summary.failedGroups.isEmpty {
          groups(
            title: "Failed · \(summary.failedCount.formatted())", groups: summary.failedGroups,
            help: nil, showsLog: true)
        }
        if !summary.brokenGroups.isEmpty {
          groups(
            title: "Already broken · \(summary.review.alreadyBroken.count.formatted())",
            groups: summary.brokenGroups, help: DomainCopy.brokenHelp, showsLog: false)
        }
        ForEach(summary.sources) { source in
          sourceRow(source)
        }
      }
      if let refusal = model.refusal {
        HStack(alignment: .firstTextBaseline, spacing: DesignMetrics.spacing.s) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(PinaxPalette.red)
          Text(refusal.message)
            .pinaxSecondary()
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if !summary.isPrefixOnly {
        Text(DomainCopy.tip)
          .pinaxCaption()
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      buttons
    }
    .sheet(
      isPresented: Binding(get: { model.diff != nil }, set: { if !$0 { model.closeChanges() } })
    ) {
      ChangesDiffSheet(text: model.diff ?? "") { model.closeChanges() }
    }
  }

  private var buttons: some View {
    HStack {
      if !summary.isPrefixOnly {
        Button("Show Changes…") { Task { await model.showChanges() } }
          .disabled(summary.review.files == 0)
      }
      Spacer()
      if summary.failedCount > 0 || model.refusal != nil {
        Button("Check Again") { Task { await model.checkAgain() } }
          .disabled(model.isBusy)
      }
      Button("Cancel") { model.dismissSheet() }
        .keyboardShortcut(.cancelAction)
      Button(summary.moveTitle) { Task { await model.confirm() } }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .tint(PinaxPalette.accentFill)
        .disabled(!model.isMoveEnabled)
    }
  }

  private var summaryCard: some View {
    VStack(spacing: 0) {
      ForEach(Array(summary.lines.enumerated()), id: \.offset) { index, line in
        if index > 0 { DomainMigrationSheet.rowDivider }
        if line.tone == .files {
          filesRow(line)
        } else {
          DomainMoveLineRow(line: line)
        }
      }
      DomainMigrationSheet.rowDivider
      checksRow
    }
    .domainCard()
  }

  /// Files to change, opening to project · files · places.
  private func filesRow(_ line: DomainMoveLine) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: DesignMetrics.spacing.s) {
        DomainMoveLineRow.icon(line.tone)
        Text(line.label).fontWeight(.semibold).lineLimit(1).fixedSize()
        Spacer(minLength: DesignMetrics.spacing.m)
        Text(line.value).monospacedDigit().lineLimit(1)
        if summary.review.files > 0 {
          Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.isFilesExpanded.toggle() }
          } label: {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(model.isFilesExpanded ? 90 : 0))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(model.isFilesExpanded ? "Hide files by project" : "Show files by project")
        }
      }
      .padding(.horizontal, DesignMetrics.spacing.m)
      .frame(height: DomainMigrationSheet.rowHeight)
      .help(line.help)
      if model.isFilesExpanded {
        ForEach(summary.review.projects.filter { $0.files > 0 }, id: \.project) { project in
          HStack {
            Text(project.project).lineLimit(1)
            Spacer()
            Text(
              "\(PinaxFormat.count(project.files, singular: "file")) · \(PinaxFormat.count(project.edits, singular: "place"))"
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
          }
          .padding(.leading, DomainMigrationSheet.rowInset + ColorSquare.Size.sidebar.side + DesignMetrics.spacing.s)
          .padding(.trailing, DesignMetrics.spacing.m)
          .frame(height: 28)
        }
      }
    }
  }

  private var checksRow: some View {
    let checks = summary.checks
    return HStack(spacing: DesignMetrics.spacing.s) {
      DomainMoveLineRow.icon(.checks)
      Text("Checks").fontWeight(.semibold).lineLimit(1).fixedSize()
      Spacer(minLength: DesignMetrics.spacing.m)
      count(checks.verified, symbol: "checkmark.circle.fill", color: PinaxPalette.green, help: summary.verifiedHelp)
      count(checks.fetchedOnly, symbol: "arrow.down.circle.fill", color: PinaxPalette.blue, help: summary.fetchedOnlyHelp)
      if checks.failed > 0 {
        count(checks.failed, symbol: "xmark.circle.fill", color: PinaxPalette.red, help: "Failed the check")
      }
    }
    .padding(.horizontal, DesignMetrics.spacing.m)
    .frame(height: DomainMigrationSheet.rowHeight)
  }

  private func count(_ n: Int, symbol: String, color: Color, help: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).foregroundStyle(color)
      Text(n.formatted()).fontWeight(.medium).monospacedDigit()
    }
    .help(help)
  }

  private func groups(title: String, groups: [DomainMoveGroup], help: String?, showsLog: Bool) -> some View {
    VStack(alignment: .leading, spacing: DesignMetrics.spacing.xs) {
      HStack {
        ExternalMigrationSheet.sectionTitle(title.uppercased())
        Spacer()
        if showsLog {
          Button("Show Log") { model.showLog() }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PinaxPalette.accent)
        }
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(groups) { group in
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(group.reason).lineLimit(1)
              Spacer()
              Text(group.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(group.shownURLs, id: \.self) { url in
              Text(url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url)
            }
            if let more = group.more {
              Text(more).pinaxCaption().foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, DesignMetrics.spacing.m)
          .padding(.vertical, DesignMetrics.spacing.s)
        }
      }
      .domainCard()
      .help(help ?? "")
    }
  }

  private func sourceRow(_ source: DomainMoveSummary.Source) -> some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(PinaxPalette.orange)
      Text(source.text)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: DesignMetrics.spacing.s)
      Toggle(
        "Write anyway",
        isOn: Binding(
          get: { model.allowedSources.contains(source.id) },
          set: { model.setSource(source.id, allowed: $0) }))
        .toggleStyle(.checkbox)
    }
    .padding(.horizontal, DesignMetrics.spacing.m)
    .padding(.vertical, DesignMetrics.spacing.s)
    .background(PinaxPalette.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

/// One summary row, as the external-image migration's: a coloured rounded icon, the label semibold, the
/// value in one line, its explanation in the tooltip.
struct DomainMoveLineRow: View {
  let line: DomainMoveLine

  static func icon(_ tone: DomainMoveLine.Tone) -> some View {
    let (symbol, color): (String, Color) =
      switch tone {
      case .files: ("pencil", ActivityEventStyle.tallyColor(.filesChanged))
      case .prefix: ("globe", PinaxPalette.accentFill)
      case .oldDomains: ("arrow.counterclockwise", PinaxPalette.orange)
      case .checks: ("checkmark", PinaxPalette.green)
      }
    return ColorSquare(size: .sidebar, color: color, content: .symbol(symbol))
  }

  var body: some View {
    HStack(spacing: DesignMetrics.spacing.s) {
      Self.icon(line.tone)
      Text(line.label).fontWeight(.semibold).lineLimit(1).fixedSize()
      Spacer(minLength: DesignMetrics.spacing.m)
      Text(line.value)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, DesignMetrics.spacing.m)
    .frame(height: DomainMigrationSheet.rowHeight)
    .help(line.help)
  }
}

extension View {
  /// The sheet's card: band fill, 10 pt corners, clipped (as the
  /// external-image migration's).
  fileprivate func domainCard() -> some View {
    background(PinaxPalette.band, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
