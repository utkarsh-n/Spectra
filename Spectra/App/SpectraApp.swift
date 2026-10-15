import SwiftUI

/// Spectra: one instrument for the electromagnetic spectrum, from the phone in your hand
/// outward. Dark only, portrait, no onboarding: it opens straight into the Spectrum tab (or
/// `-open <tab>`).
@main
struct SpectraApp: App {
  @State private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .preferredColorScheme(.dark)
        .tint(Theme.phosphor)
        .onChange(of: scenePhase) { _, phase in
          model.setActive(phase == .active)
        }
    }
  }
}
