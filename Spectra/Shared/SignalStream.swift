import Foundation

/// Stable identifier of a signal stream: `"mag.x"`, `"mag.norm"`, `"accel.z"`,
/// `"ble.<uuid>.rssi"`, `"mic.left"`, `"spin.fid"`, `"radio.i"`.
nonisolated struct StreamID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral,
  CustomStringConvertible, Comparable
{
  let rawValue: String

  init(rawValue: String) { self.rawValue = rawValue }
  init(_ rawValue: String) { self.rawValue = rawValue }
  init(stringLiteral value: String) { rawValue = value }

  var description: String { rawValue }

  static func < (lhs: StreamID, rhs: StreamID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Scope source groups, in the order the channel picker lists them.
nonisolated enum StreamGroup {
  static let magnetometer = "Magnetometer"
  static let motion = "Motion"
  static let bluetooth = "Bluetooth"
  static let network = "Network"
  static let audio = "Audio"
  static let light = "Light"
  static let air = "Air"
  static let location = "Location"
  static let device = "Device"
  static let spin = "Spin"
  static let radio = "Radio"
  static let patch = "Patch"

  static let order = [magnetometer, motion, bluetooth, network, audio, light, air, location, device, spin, radio, patch]
}

/// One time signal anything in the app produces: a sensor axis, a BLE device's RSSI, the
/// microphone, a simulated FID or I/Q stream, a Patch node output. Registered in
/// `AppModel.streams` so the Scope, Patch and Fourier views can show any of them.
///
/// The ring is written from any thread with the source's own timestamps (`SignalClock`).
nonisolated final class SignalStream: Sendable, Identifiable {
  let id: StreamID
  let label: String
  /// Physical unit as drawn: "µT", "g", "rad/s", "dBm", "Pa", "lux", "ms", "V (norm.)".
  let unit: String
  /// Hz. 0 means irregular / event-driven (BLE adverts): draw sample-and-hold.
  let nominalRate: Double
  let provenance: Provenance
  /// EM streams take their colour from `lambda`; others use the ANALOGY palette.
  let isEM: Bool
  /// Vacuum wavelength (m) of the carrier this stream describes, for colour and markers.
  let lambda: Double?
  /// One of `StreamGroup`'s names.
  let group: String
  let ring: TimestampedRing<Float>

  /// - Parameter capacity: samples kept. Defaults to 30 s at the nominal rate (audio-rate
  ///   streams, ≥ 8 kHz: 2 s; irregular streams: 4096 events).
  init(
    id: StreamID, label: String, unit: String, nominalRate: Double, provenance: Provenance,
    isEM: Bool = false, lambda: Double? = nil, group: String, capacity: Int? = nil
  ) {
    self.id = id
    self.label = label
    self.unit = unit
    self.nominalRate = max(0, nominalRate)
    self.provenance = provenance
    self.isEM = isEM
    self.lambda = lambda
    self.group = group
    ring = TimestampedRing(capacity: capacity ?? Self.defaultCapacity(rate: nominalRate))
  }

  /// 30 s at the nominal rate; 2 s for audio-rate streams; 4096 events for irregular ones.
  static func defaultCapacity(rate: Double) -> Int {
    guard rate > 0 else { return 4096 }
    let seconds = rate >= 8000 ? 2.0 : 30.0
    return max(256, Int((rate * seconds).rounded(.up)))
  }

  /// Irregular, event-driven stream (nominal rate 0).
  var isIrregular: Bool { nominalRate == 0 }

  /// Rate measured from the newest 2 s of timestamps.
  var measuredRate: Double? { ring.measuredRate(window: 2) }

  /// Convenience for producers.
  func append(_ value: Float, at time: Double) { ring.append(value, time: time) }
}
