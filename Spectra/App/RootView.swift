import SwiftUI

/// The five tabs (iOS 18+ `Tab` API, one `NavigationStack` per tab inside each tab's
/// `InstrumentScreen`), the clock driver and the toast layer.
///
/// Tab bar items carry the identifiers `tab-<rawValue>`; each tab's title carries
/// `tab-root-<rawValue>` (UI tests).
struct RootView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    @Bindable var app = app
    TabView(selection: $app.selectedTab) {
      ForEach(AppTab.allCases) { tab in
        Tab(tab.title, systemImage: tab.symbol, value: tab) {
          content(for: tab)
        }
        .accessibilityIdentifier("tab-\(tab.rawValue)")
      }
    }
    .background { ClockDriver(clock: app.clock) }
    .background(Theme.background.ignoresSafeArea())
    .overlay(alignment: .top) {
      if let toast = app.toast {
        ToastView(toast: toast) { app.dismissToast() }
          .padding(.top, 6)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(Theme.animation(reduceMotion, .spring(duration: 0.35, bounce: 0.2)), value: app.toast)
    .onChange(of: app.selectedTab) { _, _ in Haptics.shared.selection() }
  }

  @ViewBuilder
  private func content(for tab: AppTab) -> some View {
    switch tab {
    case .spectrum: SpectrumTab()
    case .radio: RadioTab()
    case .live: LiveTab()
    case .spin: SpinTab()
    case .patch: PatchTab()
    }
  }
}
