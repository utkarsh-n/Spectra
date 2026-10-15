import Foundation

/// Every live source the Live tab knows about. One `SensorChannel` exists per case.
nonisolated enum SensorID: String, CaseIterable, Codable, Sendable, Identifiable {
  case motion, magnetometer, barometer, microphone, bluetooth, network, location, light, charging, uwb, nfc

  var id: String { rawValue }

  var title: String {
    switch self {
    case .motion: "Motion"
    case .magnetometer: "Magnetometer"
    case .barometer: "Barometer"
    case .microphone: "Microphone"
    case .bluetooth: "Bluetooth"
    case .network: "Cellular & Wi-Fi"
    case .location: "Satellites (GNSS)"
    case .light: "Light meter"
    case .charging: "Charging"
    case .uwb: "Ultra wideband"
    case .nfc: "NFC"
    }
  }

  /// SF Symbol (verified in CoreGlyphs `name_availability.plist`; there is no `magnet`).
  var symbol: String {
    switch self {
    case .motion: "gyroscope"
    case .magnetometer: "location.north.line"
    case .barometer: "barometer"
    case .microphone: "mic.fill"
    case .bluetooth: "dot.radiowaves.left.and.right"
    case .network: "cellularbars"
    case .location: "location.fill"
    case .light: "sun.max"
    case .charging: "battery.100percent.bolt"
    case .uwb: "wave.3.right"
    case .nfc: "sensor.tag.radiowaves.forward"
    }
  }

  /// The `SignalStream.group` its streams belong to.
  var streamGroup: String {
    switch self {
    case .motion: StreamGroup.motion
    case .magnetometer: StreamGroup.magnetometer
    case .barometer: StreamGroup.air
    case .microphone: StreamGroup.audio
    case .bluetooth: StreamGroup.bluetooth
    case .network: StreamGroup.network
    case .location: StreamGroup.location
    case .light: StreamGroup.light
    case .charging: StreamGroup.device
    case .uwb: StreamGroup.radio
    case .nfc: StreamGroup.radio
    }
  }

  /// Whether reading this source shows a system permission prompt (requested on the tap
  /// that needs it, never at launch).
  var needsPermission: Bool {
    switch self {
    case .barometer, .microphone, .bluetooth, .location, .light, .uwb: true
    case .motion, .magnetometer, .network, .charging, .nfc: false
    }
  }
}

/// Lifecycle of one sensor channel, as the UI shows it.
nonisolated enum SensorState: Equatable, Sendable {
  case idle
  /// Waiting for the user to answer a permission prompt.
  case requesting
  case running
  /// The user said no; show "Open Settings".
  case denied
  /// No hardware or API here (e.g. the Simulator). The reason is one plain sentence.
  case unavailable(String)
  /// The API exists but needs a paid team or a peer device. The reason is one plain sentence.
  case locked(String)

  var isRunning: Bool { self == .running }

  /// Short status word for badges and the census.
  var label: String {
    switch self {
    case .idle: "Idle"
    case .requesting: "Asking…"
    case .running: "Running"
    case .denied: "Access off"
    case .unavailable: "Unavailable"
    case .locked: "Locked"
    }
  }

  /// One-line explanation, when there is one.
  var reason: String? {
    switch self {
    case .unavailable(let reason), .locked(let reason): reason
    case .denied: "Access is turned off in Settings."
    default: nil
    }
  }
}
