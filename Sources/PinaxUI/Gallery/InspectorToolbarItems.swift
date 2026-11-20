import AppKit
import SwiftUI

/// The inspector toggle is the window toolbar's *last* item,
/// and the centre column's items slide because an
/// `.inspectorTrackingSeparator` splits the toolbar into a section whose
/// trailing boundary tracks the split view's inspector divider — the same
/// NSToolbar mechanism Xcode's own split windows use. The SwiftUI toolbar
/// already runs on an NSToolbar with SwiftUI's own sidebar tracking
/// separator inserted; this mount appends the three items the inspector
/// side needs, in order when the inspector is docked:
///
///     … centre items │ inspectorTrackingSeparator │ flexibleSpace │ toggle
///
/// The inspector is docked at every window width, so
/// the separator is always installed: there is always a divider to track.
///
/// Verified in the running app (900 pt window): centre items slide
/// 467 → 686 between the two states with the system's ~200 ms easing while
/// the toggle holds 850…892 in every 40 ms sample; the separator follows
/// the inspector divider; a flexible space is required — without it the
/// toggle follows the separator (measured 670 → 912) instead of the
/// window's right edge.
///
/// The standard `toggleInspector` item dispatches nil-target
/// `-toggleInspector:` into the responder chain, which no SwiftUI responder
/// answers (measured: tryToPerform from the window returns false), and a
/// target set on it does not survive — the item manages itself back to nil
/// (measured). The mount therefore splices its coordinator between the
/// window and the rest of the chain, where the click lands and flips the
/// same `showsInspector` the ⌃⌘I command flips.
///
/// Invariants — why this shape and not another:
/// * The toggle's position is decided by toolbar layout alone: the last
///   item always hugs the window's right edge, vertically centred with the
///   other items (measured midY equal to the sidebar toggle's), with their
///   hover metrics.
/// * The centre items' slide is driven by the tracking separator following
///   the inspector divider — the system's eased transition, not an
///   animation of ours.
/// * Do not replace this with a titlebar accessory, `.offset`, or a
///   hand-drawn top bar. Each was tried and loses some of vertical
///   centring, hover metrics, and split-view-synchronised motion at once.
///   No geometry constants appear here; if one seems
///   needed, the mechanism has stopped working.
///
/// The property to keep: *the toggle's window-coordinate frame is equal
/// with the inspector shown and hidden* — asserted by
/// `LayoutStabilityTests.toggleFrameIsInvariantAcrossInspectorVisibility`
/// (the regression guard) and confirmed live by the two-state
/// measurement above (the hosted fixture does reproduce the section sliding, but
/// its toolbar region is inset — edge distances there are fixture facts).
struct InspectorToggleMount: View {
  @ObservedObject var model: GalleryModel

  var body: some View {
    Installer(model: model)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
  }

  private struct Installer: NSViewRepresentable {
    @ObservedObject var model: GalleryModel

    func makeCoordinator() -> Coordinator {
      Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
      let view = NSView(frame: .zero)
      // The view is not in a window yet at make time; the next main-actor
      // hop has it attached.
      DispatchQueue.main.async { [weak coordinator = context.coordinator] in
        coordinator?.install(in: view.window)
      }
      return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      context.coordinator.install(in: nsView.window)
    }
  }

  /// Owns the toolbar wiring for the mount's window and answers the toggle
  /// item's action from the window's responder chain. Kept alive by the
  /// representable's context (and, once spliced, the window's chain).
  final class Coordinator: NSResponder {
    let model: GalleryModel
    private var deferredAttempts = 0

    init(model: GalleryModel) {
      self.model = model
      super.init()
    }

    required init?(coder: NSCoder) {
      nil  // created in code from the mount only
    }

    /// Same state the ⌃⌘I menu command flips, through the same model call,
    /// so the button and the shortcut can never disagree.
    @objc func toggleInspector(_ sender: Any?) {
      MainActor.assumeIsolated {
        model.toggleInspector()
      }
    }

    func install(in window: NSWindow?) {
      guard let window else { return }
      // SwiftUI builds its toolbar items shortly after the window appears;
      // inserting before then would land our separator ahead of the centre
      // items. Wait for a populated items array instead of index guessing.
      guard let toolbar = window.toolbar, !toolbar.items.isEmpty else {
        deferInstall(in: window)
        return
      }
      spliceResponderChain(of: window)

      ensureToggleItems(in: toolbar)
      ensureTrackingSeparator(in: toolbar)
    }

    /// The standard item ships as nil-target `-toggleInspector:` into the
    /// responder chain and manages itself back to that state (a target we
    /// set on it measurably does not survive), while no SwiftUI responder
    /// answers the selector (measured: tryToPerform from the window
    /// returns false). Splice this coordinator between the window and
    /// whatever follows it so every dispatch path for this window —
    /// toolbar click or menu — reaches a handler flipping the same state
    /// ⌃⌘I flips. Re-checked on every install pass: whatever the window's
    /// chain looks like at attach time, an earlier SwiftUI responder swap
    /// must not silently orphan the handler.
    private func spliceResponderChain(of window: NSWindow) {
      if window.nextResponder is Coordinator { return }
      let rest = window.nextResponder
      window.nextResponder = self
      self.nextResponder = rest
    }

    private func ensureToggleItems(in toolbar: NSToolbar) {
      if !toolbar.items.contains(where: { $0.itemIdentifier == .toggleInspector }) {
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: toolbar.items.count)
        toolbar.insertItem(withItemIdentifier: .toggleInspector, at: toolbar.items.count)
      }

      guard
        let toggleIndex = toolbar.items.firstIndex(where: {
          $0.itemIdentifier == .toggleInspector
        })
      else { return }
      if toggleIndex == 0 || toolbar.items[toggleIndex - 1].itemIdentifier != .flexibleSpace {
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: toggleIndex)
      }
    }

    private func ensureTrackingSeparator(in toolbar: NSToolbar) {
      let separatorIndex = toolbar.items.firstIndex(where: {
        $0.itemIdentifier == .inspectorTrackingSeparator
      })
      // Idempotence is load-bearing, not defensive: inserting a second
      // tracking separator raises an ObjC exception (measured in the live
      // app), and updateNSView fires on every model publish.
      guard separatorIndex == nil,
        let toggleIndex = toolbar.items.firstIndex(where: {
          $0.itemIdentifier == .toggleInspector
        })
      else { return }
      let insertionIndex =
        toggleIndex > 0 && toolbar.items[toggleIndex - 1].itemIdentifier == .flexibleSpace
        ? toggleIndex - 1 : toggleIndex
      toolbar.insertItem(withItemIdentifier: .inspectorTrackingSeparator, at: insertionIndex)
    }

    private func deferInstall(in window: NSWindow) {
      deferredAttempts += 1
      guard deferredAttempts <= 20 else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.install(in: window)
      }
    }
  }
}
