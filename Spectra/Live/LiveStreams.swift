import Foundation

/// One fixed stream a Live source publishes: its stable id, label, unit, nominal rate and,
/// for radio streams, the carrier it describes (colour and markers).
nonisolated struct LiveStreamSpec: Sendable, Hashable {
  let id: StreamID
  let label: String
  let unit: String
  /// Hz. 0 = irregular (event-driven).
  let rate: Double
  /// EM carrier (Hz) the stream describes, if any.
  let carrier: Double?

  init(_ id: String, _ label: String, _ unit: String, rate: Double, carrier: Double? = nil) {
    self.id = StreamID(id)
    self.label = label
    self.unit = unit
    self.rate = rate
    self.carrier = carrier
  }

  /// A fresh stream instance for this spec (rate overrides the nominal one when the hardware
  /// reports its own, e.g. the microphone's sample rate).
  func make(provenance: Provenance, group: String, rate override: Double? = nil, capacity: Int? = nil) -> SignalStream {
    SignalStream(
      id: id, label: label, unit: unit, nominalRate: override ?? rate, provenance: provenance,
      isEM: carrier != nil, lambda: carrier.map { SpectrumMarker.lambda(forFrequency: $0) }, group: group,
      capacity: capacity)
  }
}

/// The stable stream ids every Live source publishes into `AppModel.streams` (the scope bus).
/// Other slices may hard-code these ids; they never change. `Docs/API-live.md` lists them.
nonisolated enum LiveStreams {
  // MARK: Motion (group "Motion")

  /// Raw accelerometer (g, gravity included), timestamped push at the hardware's top rate.
  static let accel = axes("accel", "Accelerometer", "g", rate: 100)
  /// User acceleration (g, gravity removed), from device motion.
  static let userAccel = axes("accel.user", "User acceleration", "g", rate: 100)
  /// Gravity (g) in the phone frame, from device motion.
  static let gravity = axes("gravity", "Gravity", "g", rate: 100)
  /// Raw gyroscope (rad/s).
  static let gyro = axes("gyro", "Gyroscope", "rad/s", rate: 100)
  /// Attitude (degrees): pitch, yaw, roll (Core Motion's Euler angles).
  static let attitude = [
    LiveStreamSpec("attitude.pitch", "Attitude pitch", "°", rate: 100),
    LiveStreamSpec("attitude.yaw", "Attitude yaw", "°", rate: 100),
    LiveStreamSpec("attitude.roll", "Attitude roll", "°", rate: 100),
  ]

  // MARK: Magnetometer (group "Magnetometer")

  /// Calibrated field (µT, device bias removed), from device motion: the DC vector and |B|.
  static let mag = axes("mag", "Magnetic field", "µT", rate: 100)
  static let magNorm = LiveStreamSpec("mag.norm", "Magnetic field |B|", "µT", rate: 100)
  /// Raw magnetometer (µT, includes the phone's own bias), timestamped push at the hardware's
  /// top rate: the ELF probe's FFT input.
  static let magRaw = axes("mag.raw", "Raw magnetometer", "µT", rate: 100)
  static let magRawNorm = LiveStreamSpec("mag.raw.norm", "Raw magnetometer |B|", "µT", rate: 100)

  // MARK: Air (group "Air")

  static let pressure = LiveStreamSpec("baro.pressure", "Air pressure", "Pa", rate: 1)
  static let relativeAltitude = LiveStreamSpec("baro.altitude", "Relative altitude", "m", rate: 1)

  // MARK: Audio (group "Audio")

  /// Microphone samples (full scale). The rate is the hardware's (48 kHz on iPhone).
  static let micLeft = LiveStreamSpec("mic.left", "Microphone", "FS", rate: 48_000)
  /// Level in dBFS per 1024-sample block.
  static let micLevel = LiveStreamSpec("mic.level", "Microphone level", "dBFS", rate: 48_000.0 / 1024)

  // MARK: Network (group "Network")

  /// Round-trip time of a TCP handshake to Apple's connectivity host (ms).
  static let rtt = LiveStreamSpec("net.rtt", "Round-trip time", "ms", rate: 1)
  /// `NWPath.linkQuality` as a step: 0 unknown, 1 minimal, 2 moderate, 3 good.
  static let quality = LiveStreamSpec("net.quality", "Link quality (0 unknown … 3 good)", "level", rate: 1)

  // MARK: Location (group "Location")

  static let hacc = LiveStreamSpec("gnss.hacc", "Horizontal accuracy", "m", rate: 1, carrier: 1575.42e6)
  static let vacc = LiveStreamSpec("gnss.vacc", "Vertical accuracy", "m", rate: 1, carrier: 1575.42e6)
  static let speed = LiveStreamSpec("gnss.speed", "Speed", "m/s", rate: 1)
  static let altitude = LiveStreamSpec("gnss.altitude", "Ellipsoidal altitude", "m", rate: 1)
  static let headingTrue = LiveStreamSpec("gnss.heading.true", "Heading (true north)", "°", rate: 0)
  static let headingMagnetic = LiveStreamSpec("gnss.heading.magnetic", "Heading (magnetic north)", "°", rate: 0)

  // MARK: Light (group "Light")

  static let lux = LiveStreamSpec("light.lux", "Illuminance", "lux", rate: 10)
  static let cct = LiveStreamSpec("light.cct", "Color temperature", "K", rate: 10)
  static let ev = LiveStreamSpec("light.ev", "Exposure value (EV100)", "EV", rate: 10)
  /// Rolling-shutter row means (experimental): a few kHz of light level from each frame.
  static let flicker = LiveStreamSpec("light.flicker", "Light flicker (row means)", "rel.", rate: 2400)

  // MARK: Device (group "Device")

  static let batteryLevel = LiveStreamSpec("battery.level", "Battery level", "%", rate: 0.2)
  /// 0 unknown, 1 unplugged, 2 charging, 3 full.
  static let batteryState = LiveStreamSpec("battery.state", "Battery state (1 unplugged · 2 charging · 3 full)", "state", rate: 0.2)
  /// `ProcessInfo.thermalState`: 0 nominal … 3 critical.
  static let thermal = LiveStreamSpec("device.thermal", "Thermal state (0 nominal … 3 critical)", "level", rate: 0.2)
  /// Proximity sensor: 1 when something covers the earpiece (only while enabled).
  static let proximity = LiveStreamSpec("device.proximity", "Proximity (1 = covered)", "state", rate: 0)

  // MARK: Radio (group "Radio")

  static let uwbDistance = LiveStreamSpec("uwb.distance", "Peer distance", "m", rate: 10, carrier: 7987.2e6)
  static let uwbAzimuth = LiveStreamSpec("uwb.azimuth", "Peer direction", "°", rate: 10)
  static let nfcTap = LiveStreamSpec("nfc.tap", "Simulated tag", "event", rate: 0.125, carrier: 13.56e6)

  // MARK: Bluetooth (group "Bluetooth")

  /// BLE advertising band centre used for colour and the strip marker.
  static let bleCarrier = 2.44e9

  /// `ble.<uuid>.rssi`: one irregular stream per advertiser (dBm).
  static func bleRSSI(_ id: UUID) -> StreamID { StreamID("ble.\(id.uuidString).rssi") }

  static func bleSpec(_ id: UUID, name: String) -> LiveStreamSpec {
    LiveStreamSpec(bleRSSI(id).rawValue, "\(name) RSSI", "dBm", rate: 0, carrier: bleCarrier)
  }

  // MARK: Catalog

  /// Every fixed-id stream a sensor can publish (BLE devices are dynamic).
  static func catalog(_ sensor: SensorID) -> [LiveStreamSpec] {
    switch sensor {
    case .motion: accel + userAccel + gravity + gyro + attitude
    case .magnetometer: mag + [magNorm] + magRaw + [magRawNorm]
    case .barometer: [pressure, relativeAltitude]
    case .microphone: [micLeft, micLevel]
    case .bluetooth: []
    case .network: [rtt, quality]
    case .location: [hacc, vacc, speed, altitude, headingTrue, headingMagnetic]
    case .light: [lux, cct, ev, flicker]
    case .charging: [batteryLevel, batteryState, thermal, proximity]
    case .uwb: [uwbDistance, uwbAzimuth]
    case .nfc: [nfcTap]
    }
  }

  /// Which sensor publishes `stream` (nil for streams the Live tab does not own).
  static func sensor(for stream: StreamID) -> SensorID? {
    let raw = stream.rawValue
    if raw.hasPrefix("ble.") { return .bluetooth }
    for sensor in SensorID.allCases where catalog(sensor).contains(where: { $0.id == stream }) { return sensor }
    return nil
  }

  private static func axes(_ prefix: String, _ label: String, _ unit: String, rate: Double) -> [LiveStreamSpec] {
    ["x", "y", "z"].map { LiveStreamSpec("\(prefix).\($0)", "\(label) \($0.uppercased())", unit, rate: rate) }
  }
}
