import Foundation

// The remaining fakes of `gyre-integration.md` §8: network, satellites, light (with the
// rolling-shutter flicker signal), charging, UWB and NFC. Like the others they write real
// timestamps at realistic rates into the same streams the live sources use. DEBUG builds
// select them (`LiveContext.simulates`); the code is plain and deterministic (`-seed N`).

// MARK: - Network

/// The cellular and Wi-Fi fake (`-fakeCell[=lte,nsa,sa,mmwave]`, `-fakeWiFi`): the radio
/// access technology steps through the list every 15 s, Wi-Fi link quality cycles
/// unknown → minimal → moderate → good, and the data path is Wi-Fi 6 when Wi-Fi is faked.
nonisolated struct NetworkFake: Sendable, Equatable {
  var technologies: [String]
  var wifi: Bool

  /// Seconds per radio access technology step.
  static let stepSeconds = 15.0

  /// The RAT on the data line at `s` seconds after start, as CoreTelephony names it.
  func technology(at s: Double) -> String? {
    guard !technologies.isEmpty else { return nil }
    let code = technologies[Int(max(0, s) / Self.stepSeconds) % technologies.count].lowercased()
    switch code {
    case "nsa": return "CTRadioAccessTechnologyNRNSA"
    case "sa", "nr", "mmwave": return "CTRadioAccessTechnologyNR"
    case "lte": return "CTRadioAccessTechnologyLTE"
    case "3g", "wcdma": return "CTRadioAccessTechnologyWCDMA"
    default: return "CTRadioAccessTechnology" + code.uppercased()
    }
  }

  /// The data path radio as `PathReport.radioType` would give it (`RadioMaps.dataPath`).
  func dataPath(at s: Double) -> String {
    if wifi { return "wifi.ax" }
    guard !technologies.isEmpty else { return "cell.lte" }
    let code = technologies[Int(max(0, s) / Self.stepSeconds) % technologies.count].lowercased()
    switch code {
    case "nsa": return "cell.nsa.sub6"
    case "sa", "nr": return "cell.sa.sub6"
    case "mmwave": return "cell.nsa.mmwave"
    default: return "cell.lte"
    }
  }

  /// `NWPath.linkQuality` as 0 unknown … 3 good: one step every 15 s.
  func quality(at s: Double) -> Int { Int(max(0, s) / Self.stepSeconds) % 4 }
}

// MARK: - Light

/// The rolling-shutter row signal of a lamp on 60 Hz mains: brightness ripples at 120 Hz
/// (twice the mains frequency) plus sensor noise, sampled at the row rate. With the flicker
/// probe's short exposure the ripple is 12 % deep; with auto exposure (1/60 s, two whole
/// flicker periods) it averages out to a trace, as it does on the device.
nonisolated struct FlickerGenerator: SimGenerator {
  let stream: SignalStream
  let flickerHz: Double
  /// Whether the short flicker exposure is locked (the Light card's switch).
  let probe: Latest<Bool>
  var grid: SampleGrid
  var rng: SimRandom

  /// Ripple depth with the short exposure, and what survives a 1/60 s exposure.
  static let lockedDepth = 0.12
  static let autoExposureDepth = 0.0005

  mutating func produce(until now: Double) {
    let (stream, f) = (stream, flickerHz)
    let depth = probe.value ? Self.lockedDepth : Self.autoExposureDepth
    var rng = rng
    var values: [Float] = []
    var times: [Double] = []
    grid.emit(until: now, cap: 4800) { t in
      let v = 0.62 * (1 + depth * sin(2 * .pi * f * t)) + 0.01 * rng.gaussian()
      values.append(Float(v))
      times.append(t)
    }
    stream.ring.append(contentsOf: values, times: times)
    self.rng = rng
  }
}

// MARK: - Charging

/// Battery and thermal fake: charging from 80 % at 1 %/min; with `-fakeMag=magsafe` the
/// phone charges only while the simulated MagSafe ring is attached (the INFERRED path).
nonisolated enum ChargingFake {
  /// (level %, state 1 unplugged · 2 charging · 3 full) at absolute time `t`.
  static func reading(at t: Double, since t0: Double, magsafe: Bool) -> (level: Double, state: Int) {
    let charging = magsafe ? SimClockPhase.magsafeAttached(at: t) : true
    let level = min(100, 80 + (t - t0) / 60)
    return (level, level >= 100 ? 3 : (charging ? 2 : 1))
  }
}

// MARK: - UWB

/// The UWB peer fake: d(t) = 1.5 + 1.0·sin(0.2 t) m, horizontal angle swinging ±40°, and the
/// convergence passing through "needs a horizontal sweep" for 4 s of every 30.
nonisolated enum UWBFake {
  static func distance(at s: Double) -> Double { 1.5 + 1.0 * sin(0.2 * s) }
  static func azimuth(at s: Double) -> Double { 40 * sin(0.13 * s) }
  static func converged(at s: Double) -> Bool { s.truncatingRemainder(dividingBy: 30) >= 4 }
}

// MARK: - NFC

/// The NFC fake (`-fakeNFC`): a simulated MIFARE tag tap every 8 s, which drives only the
/// 13.56 MHz coupling model. The card stays LOCKED.
nonisolated enum NFCFake {
  static let period = 8.0
  /// A fixed fake UID.
  static let uid = "04:A2:2C:5B:91:3E:80"
}
