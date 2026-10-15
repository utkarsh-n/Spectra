import Foundation

/// The probe presets (SPEC-features §3b). Each one names the streams it wants by meaning
/// (group, axis, keywords) so it works with the simulated streams now and the live
/// builder's real ones later, starts the sensors it needs, and sets mode, timebase, trigger
/// and coupling.
nonisolated enum ScopePreset: String, Codable, Sendable, CaseIterable, Identifiable {
  case magnetic, vibration, seismograph, bluetoothEMF, network, sound, compassXY, air, lightFlicker, spinFID, radioIQ

  var id: String { rawValue }

  var number: String {
    String(format: "%02d", (Self.allCases.firstIndex(of: self) ?? 0) + 1)
  }

  var title: String {
    switch self {
    case .magnetic: "Magnetic"
    case .vibration: "Vibration"
    case .seismograph: "Seismograph"
    case .bluetoothEMF: "Bluetooth / EMF"
    case .network: "Network"
    case .sound: "Sound"
    case .compassXY: "Compass XY"
    case .air: "Air"
    case .lightFlicker: "Light flicker"
    case .spinFID: "Spin FID"
    case .radioIQ: "Radio I/Q"
    }
  }

  var symbol: String {
    switch self {
    case .magnetic: "location.north.line"
    case .vibration: "waveform.path.ecg"
    case .seismograph: "waveform.path"
    case .bluetoothEMF: "dot.radiowaves.left.and.right"
    case .network: "network"
    case .sound: "mic.fill"
    case .compassXY: "location.circle"
    case .air: "barometer"
    case .lightFlicker: "lightbulb.max"
    case .spinFID: "gyroscope"
    case .radioIQ: "antenna.radiowaves.left.and.right"
    }
  }

  /// The honest one-paragraph caption shown under the probe chips.
  var caption: String {
    switch self {
    case .magnetic:
      "Magnetometer X, Y, Z and |B| in µT. X, Y and Z are AC-coupled so mains hum near a cable or charger stands out. The sensor samples at about 100 Hz, so hum folds back below 50 Hz: 60 Hz shows up near 40 Hz, and 50 Hz sits right at the limit as a slow beat. Open FFT to see the alias."
    case .vibration:
      "Accelerometer X, Y, Z with gravity removed, plus the gyroscope's |ω| as the math trace. Put the phone on a washing machine, a table you tap, or a speaker; RMS reads in mg."
    case .seismograph:
      "Accelerometer Z, high-passed, rolling at 1 s per division and auto-scaled. Lay the phone flat on a table and tap near it."
    case .bluetoothEMF:
      "RSSI of the three strongest Bluetooth radios (dBm, drawn sample-and-hold because adverts arrive irregularly) and the magnetic field |B|. The phone has no broadband RF power meter: RSSI is one device's radio strength at 2.4 GHz, and the magnetometer only sees fields from DC to about 50 Hz."
    case .network:
      "Round-trip time (ms) of a connection handshake over whichever link carries your traffic (Wi-Fi or cellular), above, and link quality as steps below, about once a second."
    case .sound:
      "The microphone at 48 kHz, 1 ms per division, triggered on rising edges. This is sound, not light: an analogy for the waves in the rest of the app. FFT reaches 24 kHz."
    case .compassXY:
      "Magnetometer X against Y. Turn the phone flat on a table: the trace draws a circle, offset and squashed by the phone's own magnetism (the calibration ellipse)."
    case .air:
      "Air pressure (Pa, above) and relative altitude (m, below). Walk up a flight of stairs: about 12 Pa per meter."
    case .lightFlicker:
      "Experimental: the camera's rolling shutter reads rows at different instants, so the mean of each row is a light signal at several kHz. LED and lamp flicker at 100 or 120 Hz (twice the mains) shows up on it. The row time is not published, so the time axis is a model; validate it on the device against a known lamp."
    case .spinFID:
      "A proton free-induction decay at its true pitch in the live field |B| (about 2.1 kHz at 50 µT), repeated every 3 s. Your phone measures the field; the spins are simulated."
    case .radioIQ:
      "EDGE 8-PSK baseband I against Q through a 30 dB channel, slowed down so the symbol trajectory is visible. Simulated by the RF engine."
    }
  }

  /// The sensors this probe starts while the scope is visible.
  var sensors: [SensorID] {
    switch self {
    case .magnetic, .compassXY: [.magnetometer]
    case .vibration, .seismograph: [.motion]
    case .bluetoothEMF: [.bluetooth, .magnetometer]
    case .network: [.network]
    case .sound: [.microphone]
    case .air: [.barometer]
    case .lightFlicker: [.light]
    case .spinFID: [.magnetometer]
    case .radioIQ: []
    }
  }

  /// Simulated streams this probe needs the scope to publish when nobody else does.
  var modelStreams: [ScopeProbeKind] {
    switch self {
    case .spinFID: [.spinFID]
    case .radioIQ: [.radioIQ]
    default: []
    }
  }

  /// Looks a preset up by id or by a loose title ("Magnetic scope", "spin fid", "radio-iq").
  init?(name: String) {
    let key = name.lowercased().filter { $0.isLetter }
    guard !key.isEmpty else { return nil }
    if let exact = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) {
      self = exact
      return
    }
    let match = Self.allCases.first { p in
      let t = p.title.lowercased().filter { $0.isLetter }
      return key.hasPrefix(t) || t.hasPrefix(key) || key.contains(t)
    }
    guard let match else { return nil }
    self = match
  }

  /// Writes this probe into `s`: channel queries (resolved later against the registry),
  /// mode, timebase, trigger, coupling, math and persistence.
  func configure(_ s: inout ScopeSettings) {
    typealias Q = ScopeEngine.StreamQuery
    var next = ScopeSettings()
    next.preset = self
    next.cursors = s.cursors
    next.cursors.mode = .off
    func channel(_ q: Q?, coupling: ScopeCoupling = .dc, upd: Double = 1, auto: Bool = true) -> ScopeChannel {
      ScopeChannel(stream: nil, query: q, enabled: q != nil, unitsPerDiv: upd, coupling: coupling, autoScale: auto)
    }
    let mag = StreamGroup.magnetometer
    let calibrated = ["calibrated", "cal"]
    let raw = ["raw", "uncal"]
    switch self {
    case .magnetic:
      next.channels = [
        // Auto-scaled into their 1.6-division bands, so a strong hum or a passing magnet on one
        // axis never runs off the top of the screen or into the next trace.
        channel(Q(group: mag, axis: "x", prefer: calibrated, avoid: raw), coupling: .ac, upd: 2),
        channel(Q(group: mag, axis: "y", prefer: calibrated, avoid: raw), coupling: .ac, upd: 2),
        channel(Q(group: mag, axis: "z", prefer: calibrated, avoid: raw), coupling: .ac, upd: 2),
        channel(Q(group: mag, any: ["norm", "|b|", "magnitude", "total"], avoid: raw)),
      ]
      // Stacked like a four-trace bench scope: X, Y, Z, then |B| at the bottom.
      for (i, p) in [3.0, 1, -1, -3].enumerated() { next.channels[i].position = p }
      next.mode = .yt
      next.timebase = 0.05
      next.trigger = ScopeTrigger(mode: .auto, source: 0, level: 0, slope: .rising, holdoff: 0)
      next.persistence = 0.25
    case .vibration:
      let accel = ["accel", "acceleration"]
      next.channels = ["x", "y", "z"].map { axis in
        channel(Q(group: StreamGroup.motion, axis: axis, any: accel, prefer: ["user"], avoid: ["gravity", "raw"]),
          coupling: .removeGravity, upd: 0.01)
      } + [channel(Q(group: StreamGroup.motion, any: ["gyro", "rotation"], prefer: ["norm", "magnitude", "|ω|"]))]
      next.channels[3].enabled = false
      next.channels[3].query = nil
      for (i, p) in [3.0, 1, -1].enumerated() { next.channels[i].position = p }
      next.math = ScopeMath()
      next.math.enabled = true
      next.math.operation = .magnitude
      next.math.label = "|ω|"
      next.math.queries = ["x", "y", "z"].map {
        Q(group: StreamGroup.motion, axis: $0, any: ["gyro", "rotation"], avoid: ["raw", "uncal"])
      }
      next.math.a = .stream("gyro.x")
      next.math.b = .stream("gyro.y")
      next.math.c = .stream("gyro.z")
      next.math.position = -3
      next.mode = .yt
      next.timebase = 0.1
      next.trigger = ScopeTrigger(mode: .auto, source: 2, level: 0, slope: .rising, holdoff: 0)
      next.persistence = 0.5
    case .seismograph:
      next.channels = [
        channel(
          Q(group: StreamGroup.motion, axis: "z", any: ["accel", "acceleration"], prefer: ["user"], avoid: ["gravity", "raw"]),
          coupling: .removeGravity, upd: 0.002),
        channel(nil), channel(nil), channel(nil),
      ]
      next.mode = .roll
      next.timebase = 1
      next.persistence = 0
    case .bluetoothEMF:
      next.channels = (0..<3).map { i in
        channel(Q(group: StreamGroup.bluetooth, any: ["rssi"], rank: .strongest(i)), upd: 20, auto: false)
      } + [channel(Q(group: mag, any: ["norm", "|b|", "magnitude", "total"], avoid: raw))]
      for i in 0..<3 {
        next.channels[i].reference = -65
        next.channels[i].position = 1.5
      }
      next.channels[3].position = -3
      next.mode = .roll
      next.timebase = 1
      next.persistence = 0
    case .network:
      // One RTT stream (the handshake over whichever link carries traffic) and link quality,
      // each in its own band. A separate "cellular RTT" channel would wait forever: nothing
      // publishes one.
      next.channels = [
        channel(Q(group: StreamGroup.network, any: ["rtt", "round", "latency", "ms"], prefer: ["wifi", "wi-fi"])),
        channel(Q(group: StreamGroup.network, any: ["quality", "link"], prefer: ["wifi", "wi-fi"])),
        channel(nil), channel(nil),
      ]
      next.channels[0].position = 2
      next.channels[1].position = -2
      next.mode = .roll
      next.timebase = 2
      next.persistence = 0
    case .sound:
      next.channels = [
        channel(Q(group: StreamGroup.audio, avoid: ["level", "dbfs"], rank: .fastest), coupling: .ac, upd: 0.1),
        channel(nil), channel(nil), channel(nil),
      ]
      next.mode = .yt
      next.timebase = 0.001
      next.trigger = ScopeTrigger(mode: .auto, source: 0, level: 0, slope: .rising, holdoff: 0)
      next.persistence = 0.15
    case .compassXY:
      next.channels = [
        channel(Q(group: mag, axis: "x", prefer: calibrated, avoid: raw), upd: 10, auto: false),
        channel(Q(group: mag, axis: "y", prefer: calibrated, avoid: raw), upd: 10, auto: false),
        channel(nil), channel(nil),
      ]
      next.mode = .xy
      next.xChannel = 0
      next.yChannel = 1
      next.timebase = 1
      next.persistence = 3
    case .air:
      next.channels = [
        channel(Q(group: StreamGroup.air, any: ["pressure", "pa"])),
        channel(Q(group: StreamGroup.air, any: ["altitude", "height"])),
        channel(nil), channel(nil),
      ]
      // Pressure above, altitude below: they mirror each other, so on one band they would cross.
      next.channels[0].position = 2
      next.channels[1].position = -2
      next.mode = .roll
      next.timebase = 5
      next.persistence = 0
    case .lightFlicker:
      next.channels = [
        channel(Q(group: StreamGroup.light, any: ["flicker", "row"]), coupling: .ac),
        channel(Q(group: StreamGroup.light, any: ["lux", "illuminance"])),
        channel(nil), channel(nil),
      ]
      next.channels[1].enabled = true
      // The flicker above, the (10 Hz, held) illuminance below, each in its own band.
      next.channels[0].position = 2
      next.channels[1].position = -2
      next.mode = .yt
      next.timebase = 0.005
      next.trigger = ScopeTrigger(mode: .auto, source: 0, level: 0, slope: .rising, holdoff: 0)
      next.persistence = 0.2
    case .spinFID:
      next.channels = [
        channel(Q(group: StreamGroup.spin, any: ["fid"], avoid: ["tip"]), upd: 0.5, auto: false),
        channel(nil), channel(nil), channel(nil),
      ]
      next.mode = .roll
      next.timebase = 0.5
      next.persistence = 0
    case .radioIQ:
      next.channels = [
        channel(Q(group: StreamGroup.radio, any: ["radio.i", " i", "in-phase"], avoid: ["radio.q", "quadrature"]), upd: 0.5, auto: false),
        channel(Q(group: StreamGroup.radio, any: ["radio.q", " q", "quadrature"]), upd: 0.5, auto: false),
        channel(nil), channel(nil),
      ]
      next.mode = .xy
      next.xChannel = 0
      next.yChannel = 1
      next.timebase = 0.2
      next.persistence = 1
    }
    next.analysisChannel = 0
    next.measureChannel = 0
    next.logFrequency = s.logFrequency
    s = next
  }
}
