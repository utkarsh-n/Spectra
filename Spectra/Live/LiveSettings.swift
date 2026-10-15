import Foundation
import Observation

/// The Live tab's own knobs and assumptions, persisted under `Spectra.live.v1`: the
/// Bluetooth path-loss exponent, the Wi-Fi band you assume (iOS does not say), the air's
/// temperature, humidity and refractivity gradient (no public API measures them), the
/// camera and probe switches, and the magnetometer analysis window.
nonisolated struct LivePreferences: Codable, Sendable, Equatable {
  /// Log-distance path-loss exponent n for BLE distance estimates (2 free space … 4 indoors).
  var bleExponent = 2.7
  /// The Wi-Fi band you assume the phone is on (MODEL).
  var wifiBand: RadioMaps.WiFiBand = .ghz5
  /// Air temperature (°C) and relative humidity (%) for refractivity.
  var airTemperature = 20.0
  var airHumidity = 50.0
  /// Refractivity gradient dN/dh (N-units per km); −40 is the standard atmosphere (k ≈ 4/3).
  var refractivityGradient = -40.0
  /// Antenna height above the ground where the barometer started (m).
  var antennaHeight = 1.5
  /// Light meter uses the front (selfie) camera.
  var frontCamera = false
  /// Light meter locks a short exposure so lamp flicker shows in the row signal.
  var flickerProbe = false
  /// Proximity monitoring (blanks the screen when covered).
  var proximity = false
  /// Magnetometer FFT length: 256, 512 or 1024 samples.
  var magnetometerFFT = 512
  /// Your mains frequency for the aliasing explainer (50 or 60 Hz).
  var mains = 60.0
  /// Virtual sample rate for the folding diagram (Hz); nil follows the measured rate.
  var virtualRate: Double?

  init() {}

  init(from decoder: any Decoder) throws {
    let d = LivePreferences()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
    bleExponent = min(6, max(1.5, v(.bleExponent, d.bleExponent)))
    wifiBand = v(.wifiBand, d.wifiBand)
    airTemperature = min(50, max(-40, v(.airTemperature, d.airTemperature)))
    airHumidity = min(100, max(0, v(.airHumidity, d.airHumidity)))
    refractivityGradient = min(100, max(-300, v(.refractivityGradient, d.refractivityGradient)))
    antennaHeight = min(10_000, max(0, v(.antennaHeight, d.antennaHeight)))
    frontCamera = v(.frontCamera, d.frontCamera)
    flickerProbe = v(.flickerProbe, d.flickerProbe)
    proximity = false  // never restored: it blanks the screen
    let n = v(.magnetometerFFT, d.magnetometerFFT)
    magnetometerFFT = [256, 512, 1024].contains(n) ? n : 512
    mains = v(.mains, d.mains) == 50 ? 50 : 60
    virtualRate = (try? c.decodeIfPresent(Double.self, forKey: .virtualRate)).flatMap { $0 }.map { min(200, max(20, $0)) }
  }
}

/// Owner of `LivePreferences` (`@MainActor`, debounced persistence like every tab model).
@Observable @MainActor
final class LiveSettings {
  var prefs: LivePreferences {
    didSet {
      guard prefs != oldValue else { return }
      store?.schedule(prefs)
    }
  }

  @ObservationIgnored private let store: JSONStore<LivePreferences>?

  static let storageKey = "Spectra.live.v1"

  init(launch: LaunchOptions) {
    if launch.uiTesting {
      store = nil
      prefs = LivePreferences()
    } else {
      let store = JSONStore<LivePreferences>(key: Self.storageKey, defaults: .standard)
      self.store = store
      prefs = store.load() ?? LivePreferences()
    }
  }

  /// Back to the defaults (Dials → Reset dials).
  func reset() { prefs = LivePreferences() }

  func flush() { store?.flush() }
}
