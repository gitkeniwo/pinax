import PinaxUI
import SwiftUI

@main
struct PinaxAppApp: App {
  @NSApplicationDelegateAdaptor(PinaxAppDelegate.self) private var appDelegate
  @StateObject private var app = PinaxAppModel()

  var body: some Scene {
    Window("Pinax", id: "gallery") {
      GalleryRootView(app: app)
    }
    .defaultSize(width: 1100, height: 720)
    // The gallery draws its own title area (title over
    // the current project's picker button); unified keeps the toolbar at
    // the system title's height (measured).
    .windowToolbarStyle(.unified(showsTitle: false))
    .keyboardShortcut("0", modifiers: .command)
    Settings {
      PinaxSettingsView(preferences: app.preferences, app: app)
    }
    .windowResizability(.contentSize)
    MenuBarExtra {
      // Opening the panel marks the failures seen, at the panel's own
      // refresh point.
      PinaxMenuBarContent(app: app)
    } label: {
      MenuBarIconLabel(preferences: app.preferences, activity: app.menuBarActivity)
    }
    .menuBarExtraStyle(.window)
    .commands {
      PinaxCommands(app: app)
    }
  }
}
