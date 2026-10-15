import Foundation
import Observation
import SwiftUI

/// What every tab's model provides to the loop. Owners replacing a stub keep the type name,
/// `init()`, `markers` and this conformance (`attach(to:)` may stay the default no-op).
@MainActor
protocol TabModel: AnyObject {
  /// Every active frequency this model shows, for the Spectrum strip and tuner.
  var markers: [SpectrumMarker] { get }
  /// Called once after `AppModel` has built every sub-model, so a model can reach the clock,
  /// streams, haptics, synth, sensors or the other tabs. Keep the reference `weak`.
  func attach(to app: AppModel)
}

extension TabModel {
  func attach(to app: AppModel) {}
}

/// A transient glass message at the top of the screen ("Spectrum tuned to 2.44 GHz").
struct Toast: Identifiable, Equatable {
  let id = UUID()
  var text: String
  var symbol: String
}

/// The root of the loop (SPEC.md §3.4): one clock, one stream registry, one haptics service,
/// one synth, the five tab models, settings, and the cross-tab actions (`focus`,
/// `sendToSpectrum`, `showToast`). Injected with `.environment(model)`; read it in views with
/// `@Environment(AppModel.self) private var app`.
@Observable @MainActor
final class AppModel {
  let launch: LaunchOptions
  let clock: AppClock
  /// The universal scope bus.
  let streams: StreamRegistry
  let haptics: Haptics
  let synth: HumSynth

  let spectrum: SpectrumModel
  let radio: RadioModel
  let live: SensorHub
  let spin: SpinModel
  let patch: PatchModel

  /// The visible tab.
  var selectedTab: AppTab
  /// The marker most recently focused from a strip (tabs may highlight it).
  var focusedMarker: SpectrumMarker?
  /// The latest "Open in Scope" request; the Live tab switches to its Scope page when it changes.
  var scopeRequest: ScopeRequest?
  /// App-wide preferences; changes apply at once and persist after 400 ms.
  var settings: AppSettings {
    didSet {
      guard settings != oldValue else { return }
      applySettings()
      settingsStore.schedule(settings)
    }
  }
  private(set) var toast: Toast?
  /// True while the scene is active.
  private(set) var isActive = true

  private let settingsStore: JSONStore<AppSettings>
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  /// - Parameters:
  ///   - launch: launch arguments (`-open`, `-ui-testing`, DEBUG fakes).
  ///   - defaults: where settings persist; `-ui-testing` uses a throwaway suite.
  init(launch: LaunchOptions = .current, defaults: UserDefaults? = nil) {
    self.launch = launch
    let store: UserDefaults
    if let defaults {
      store = defaults
    } else if launch.uiTesting {
      let suite = "Spectra.uitesting"
      UserDefaults().removePersistentDomain(forName: suite)
      store = UserDefaults(suiteName: suite) ?? .standard
    } else {
      store = .standard
    }
    settingsStore = JSONStore(key: AppSettings.storageKey, defaults: store)
    settings = launch.uiTesting ? AppSettings() : (settingsStore.load() ?? AppSettings())
    clock = AppClock(playing: !launch.uiTesting)
    let registry = StreamRegistry()
    streams = registry
    haptics = .shared
    synth = .shared
    spectrum = SpectrumModel()
    radio = RadioModel()
    live = SensorHub(streams: registry, launch: launch)
    spin = SpinModel()
    patch = PatchModel()
    selectedTab = launch.openTab ?? .spectrum

    applySettings()
    for model in tabModels { model.attach(to: self) }
  }

  /// The five tab models in tab order.
  var tabModels: [any TabModel] { [spectrum, radio, live, spin, patch] }

  /// Every sub-model's markers, deduplicated by id (first wins), shortest wavelength first.
  var markers: [SpectrumMarker] {
    Self.union(tabModels.map(\.markers))
  }

  /// The union of marker lists: deduplicated by id (first wins), sorted by wavelength.
  nonisolated static func union(_ lists: [[SpectrumMarker]]) -> [SpectrumMarker] {
    var seen = Set<String>()
    var out: [SpectrumMarker] = []
    for list in lists {
      for marker in list where marker.lambda.isFinite && marker.lambda > 0 && seen.insert(marker.id).inserted {
        out.append(marker)
      }
    }
    return out.sorted { $0.lambda == $1.lambda ? $0.id < $1.id : $0.lambda < $1.lambda }
  }

  // MARK: Cross-tab actions

  /// Jumps to the tab that owns `marker` (tap on a strip marker).
  func focus(_ marker: SpectrumMarker) {
    focusedMarker = marker
    if selectedTab != marker.tab {
      selectedTab = marker.tab  // RootView plays the selection haptic on tab changes.
    } else {
      haptics.tap()
    }
  }

  /// Tunes Spectrum source A to `lambda` (metres), switches to the Spectrum tab and says so.
  func sendToSpectrum(lambda: Double, label: String) {
    guard lambda.isFinite, lambda > 0 else {
      haptics.boundary()
      return
    }
    spectrum.tune(lambda: lambda)
    if selectedTab != .spectrum { selectedTab = .spectrum }
    haptics.success()
    showToast(
      "Source A tuned to \(label) · \(SpectraFormat.wavelength(lambda))", symbol: "waveform")
  }

  /// Shows `streams` in the Scope (Live tab → Scope page), optionally with a probe preset.
  func openScope(_ streams: [StreamID], preset: String? = nil) {
    scopeRequest = ScopeRequest(streams: streams, preset: preset)
    if selectedTab != .live { selectedTab = .live } else { haptics.tap() }
  }

  /// Shows a toast for 2.4 s (a newer toast replaces it).
  func showToast(_ text: String, symbol: String = "checkmark") {
    toastTask?.cancel()
    toast = Toast(text: text, symbol: symbol)
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.4))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  func dismissToast() {
    toastTask?.cancel()
    toast = nil
  }

  // MARK: Lifecycle

  /// Scene phase. Inactive holds the clock, pauses sound, stops sensors and haptics, and
  /// writes pending settings.
  func setActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    clock.setActive(active)
    synth.setActive(active)
    live.setActive(active)
    if !active {
      haptics.stop()
      settingsStore.flush()
    }
  }

  /// Writes pending settings now.
  func save() { settingsStore.flush() }

  /// Restores default settings (Settings → Reset).
  func resetSettings() { settings = AppSettings() }

  private func applySettings() {
    haptics.enabled = settings.hapticsOn
    haptics.strength = settings.hapticStrength
    haptics.humAllowed = settings.continuousHum
    synth.enabled = settings.soundOn
    let synth = synth
    haptics.soundTick = settings.soundOn ? { kind in synth.tick(kind) } : nil
    live.apply(settings)
  }
}
