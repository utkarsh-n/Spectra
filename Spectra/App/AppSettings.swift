import Foundation

/// App-wide preferences (Settings sheet). Persisted as JSON under `Spectra.settings.v1`.
/// Decoding tolerates missing keys, so adding a field never loses a user's settings.
nonisolated struct AppSettings: Codable, Equatable, Sendable {
  /// Synth sounds (pitch mapped from frequency; Spin plays true-pitch precession). Off by default.
  var soundOn = false
  var hapticsOn = true
  /// Global haptic strength 0…1 (Orbitals default 0.85).
  var hapticStrength = 0.85
  /// Continuous haptic hum for live signal strength and spin. Off by default.
  var continuousHum = false
  var powerUnit: PowerUnit = .dBm
  var distanceUnit: DistanceUnit = .metric
  /// Sources the user switched off in Settings → Sensors.
  var disabledSensors: Set<SensorID> = []
  /// DEBUG builds: use simulated sensors even where hardware exists.
  var simulation: SimulationPreference = .automatic

  static let storageKey = "Spectra.settings.v1"

  init() {}

  private enum CodingKeys: String, CodingKey {
    case soundOn, hapticsOn, hapticStrength, continuousHum, powerUnit, distanceUnit, disabledSensors, simulation
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = AppSettings()
    soundOn = try c.decodeIfPresent(Bool.self, forKey: .soundOn) ?? d.soundOn
    hapticsOn = try c.decodeIfPresent(Bool.self, forKey: .hapticsOn) ?? d.hapticsOn
    let strength = try c.decodeIfPresent(Double.self, forKey: .hapticStrength) ?? d.hapticStrength
    hapticStrength = strength.isFinite ? min(1, max(0, strength)) : d.hapticStrength
    continuousHum = try c.decodeIfPresent(Bool.self, forKey: .continuousHum) ?? d.continuousHum
    powerUnit = (try? c.decodeIfPresent(PowerUnit.self, forKey: .powerUnit)) ?? d.powerUnit
    distanceUnit = (try? c.decodeIfPresent(DistanceUnit.self, forKey: .distanceUnit)) ?? d.distanceUnit
    disabledSensors = (try? c.decodeIfPresent(Set<SensorID>.self, forKey: .disabledSensors)) ?? d.disabledSensors
    simulation = (try? c.decodeIfPresent(SimulationPreference.self, forKey: .simulation)) ?? d.simulation
  }

  func isEnabled(_ sensor: SensorID) -> Bool { !disabledSensors.contains(sensor) }
}

nonisolated enum PowerUnit: String, Codable, CaseIterable, Sendable, Identifiable {
  case dBm, watts
  var id: String { rawValue }
  var title: String { self == .dBm ? "dBm" : "Watts" }
}

nonisolated enum DistanceUnit: String, Codable, CaseIterable, Sendable, Identifiable {
  case metric, imperial
  var id: String { rawValue }
  var title: String { self == .metric ? "Metric" : "Imperial" }
}

nonisolated enum SimulationPreference: String, Codable, CaseIterable, Sendable, Identifiable {
  /// Real sensors where they exist, simulated where they don't (the Simulator).
  case automatic
  /// Simulated sensors everywhere (DEBUG only).
  case always
  var id: String { rawValue }
  var title: String { self == .automatic ? "Where needed" : "Always" }
}

/// Debounced JSON persistence in `UserDefaults` (Orbitals pattern: one versioned key, saves
/// coalesced for 400 ms, flushed immediately when the app leaves the foreground).
///
/// Each sub-model owns one: `JSONStore<RadioState>(key: "Spectra.radio.v1")`.
@MainActor
final class JSONStore<Value: Codable> {
  let key: String
  private let defaults: UserDefaults
  private let delay: Duration
  private var pending: Value?
  private var task: Task<Void, Never>?

  init(key: String, defaults: UserDefaults = .standard, delay: Duration = .milliseconds(400)) {
    self.key = key
    self.defaults = defaults
    self.delay = delay
  }

  /// The stored value, or nil if absent or unreadable.
  func load() -> Value? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(Value.self, from: data)
  }

  /// Saves after the debounce delay; a newer value replaces a pending one.
  func schedule(_ value: Value) {
    pending = value
    task?.cancel()
    let delay = delay
    task = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  /// Saves immediately.
  func save(_ value: Value) {
    task?.cancel()
    task = nil
    pending = nil
    if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
  }

  /// Writes a pending value now (call on background / scene inactive).
  func flush() {
    guard let value = pending else { return }
    save(value)
  }

  var hasPending: Bool { pending != nil }

  func clear() {
    task?.cancel()
    task = nil
    pending = nil
    defaults.removeObject(forKey: key)
  }
}
